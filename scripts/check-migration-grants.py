#!/usr/bin/env python3
"""check-migration-grants.py - fail a Supabase migration that creates a `public` table or view
without explicit Data API grants.

WHY: from 2026-10-30 Supabase stops auto-granting anon / authenticated / service_role on NEW
`public` tables (and sequences) in existing projects; existing tables keep their grants.
Without a GRANT, supabase-js / PostgREST / GraphQL answer 42501 "permission denied". The grant
has to ship in the same migration that creates the table.

RULES (per migration file, evaluated on the END state of its GRANT/REVOKE statements):
  G001 relation created without a grant to anon, authenticated or service_role. A relation that
       is deliberately closed to the Data API is annotated `-- data-api: none (<reason>)`.
  G002 table created without `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` in the same file.
  G003 anon (or PUBLIC) holds a privilege on a new relation that was granted without a
       `-- anon-ok: <reason>` on that GRANT line or the comment block just above it. The reason
       is per privilege: a reason on `grant select` does not cover a later `grant insert`.
  G004 blanket exposure re-created: GRANT ... ON ALL TABLES/SEQUENCES/FUNCTIONS IN SCHEMA, or
       ALTER DEFAULT PRIVILEGES ... GRANT, to anon / authenticated / PUBLIC.
  G005 serial column whose sequence gets no USAGE/UPDATE grant (identity columns need none).
Warning (never fails): a dynamic CREATE TABLE inside a DO block or function body is not analysed.

A relation counts as created by CREATE TABLE/VIEW (CREATE OR REPLACE VIEW included: the lint cannot
see whether the view exists, and re-stating a grant is harmless), CREATE TABLE AS, SELECT ... INTO
schema.t, and ALTER ... SET SCHEMA into a guarded schema; ALTER ... RENAME TO follows the relation.
Unqualified names count as `public` unless the file sets search_path (first non-"$user" entry).
`GRANT ... ON ALL TABLES IN SCHEMA public TO service_role` is accepted as an explicit grant.
TEMP relations and PARTITION OF children are skipped (a partition is reached through its parent).

KNOWN LIMITS (reviewed 2026-10-20, not detected): `set_config('search_path', ...)`, CREATE SEQUENCE
and `default nextval('x')` columns, function EXECUTE grants, and ownership/ACL changes made outside
the file. The baseline key is file|relation|rule, so a NEW statement against an already-baselined
relation in the same file is not seen (G004 keys carry a statement hash and are not affected).
In a DO-wrapped migration put `-- data-api: none (...)` / `-- anon-ok: ...` directly above the
statement INSIDE the block, not above `do $m$`.

USAGE: check-migration-grants.py [--baseline FILE] [--write-baseline] [--schemas public]
       [--exclude '*/tests/*' ...] PATH...
PATH is a .sql file, a directory (recursive) or a glob. Findings listed in the baseline are
grandfathered (migrations applied before this check existed); anything else exits 1. Exit 2 =
usage error, or ANY path argument that matches no .sql file (a misspelled path or glob must not
pass vacuously).
"""
import argparse, fnmatch, glob, hashlib, os, re, sys

API = {"anon", "authenticated", "service_role"}
OPEN = {"anon", "authenticated", "public"}
TABLE_PRIVS = {"select", "insert", "update", "delete", "truncate", "references", "trigger", "maintain"}
PRIVS = TABLE_PRIVS | {"all", "usage", "execute"}
SEQ_PRIVS = {"usage", "select", "update"}  # nextval() needs USAGE or UPDATE; SELECT alone only reads last_value
ID = r'(?:"(?:[^"]|"")+"|[A-Za-z_][\w$]*)'
QN = rf"{ID}(?:\s*\.\s*{ID})?"
CREATE = re.compile(rf"^\s*create\s+(?P<m>(?:(?:global\s+|local\s+)?temp(?:orary)?\s+|unlogged\s+|materialized\s+|or\s+replace\s+|recursive\s+)*)(?P<k>table|view)\s+(?:if\s+not\s+exists\s+)?(?P<n>{QN})", re.I)
GRANT = re.compile(r"^\s*(?P<v>grant|revoke)\s+(?P<go>grant\s+option\s+for\s+)?(?P<p>.+?)\s+on\s+(?P<t>.+?)\s+(?:to|from)\s+(?P<r>.+?)(?:\s+with\s+grant\s+option|\s+cascade|\s+restrict)?\s*$", re.I | re.S)
ADP = re.compile(r"^\s*alter\s+default\s+privileges\b(?P<b>.*)$", re.I | re.S)
RLS = re.compile(rf"^\s*alter\s+table\s+(?:if\s+exists\s+)?(?:only\s+)?(?P<n>{QN})\s+enable\s+row\s+level\s+security", re.I)
SEARCH = re.compile(r"^\s*set\s+(?:local\s+|session\s+)?search_path\s*(?:to|=)\s*(?P<s>.+)$", re.I | re.S)
SERIAL = re.compile(rf"(?:^|[(,])\s*(?P<c>{ID})\s+(?:small|big)?serial[248]?\b", re.I)
MOVE = re.compile(rf"^\s*alter\s+(?P<k>table|view|materialized\s+view)\s+(?:if\s+exists\s+)?(?:only\s+)?(?P<n>{QN})\s+set\s+schema\s+(?P<to>{ID})\s*$", re.I)
RENAME = re.compile(rf"^\s*alter\s+(?:table|view|materialized\s+view)\s+(?:if\s+exists\s+)?(?:only\s+)?(?P<n>{QN})\s+rename\s+to\s+(?P<to>{ID})\s*$", re.I)
SELINTO = re.compile(rf"^\s*select\b[^;]*?\binto\s+(?:unlogged\s+)?(?:table\s+)?(?P<n>{ID}\s*\.\s*{ID})(?=\s|$)", re.I | re.S)  # schema-qualified only: plpgsql variables never are
NONE = re.compile(r"data-api:\s*none\b[\s(:-]*\S.{2,}", re.I)
ANON_OK = re.compile(r"anon-ok:\s*\S{3,}", re.I)
WRAP = re.compile(r"^\s*(?:begin\b|else\b|loop\b|(?:if|elsif|when)\b[^;]*?\bthen\b)\s*", re.I | re.S)


def nid(s):
    s = s.strip()
    return s[1:-1].replace('""', '"') if s.startswith('"') else s.lower()


def unwrap(s):  # strip plpgsql openers so `BEGIN create table ..` and `IF .. THEN create table ..` match
    while (m := WRAP.match(s)) and m.end():
        s = s[m.end():]
    return s


def qname(s, default):
    p = re.findall(ID, s)
    return (nid(p[0]), nid(p[1])) if len(p) >= 2 else (default, nid(p[0]))


def seq_name(table, col):
    """Name Postgres gives a serial column's sequence: makeObjectName(table, col, 'seq') truncates the
    longer of table / column until `<table>_<col>_seq` fits in 63 bytes."""
    a, b, avail = table.encode(), col.encode(), 63 - (1 + len("seq") + 1)
    while len(a) + len(b) > avail:
        a, b = (a[:-1], b) if len(a) > len(b) else (a, b[:-1])
    return f"{a.decode('utf-8', 'ignore')}_{b.decode('utf-8', 'ignore')}_seq"


def split_sql(text, line=1):
    """-> (statements [(clean_text, first_line, last_line)], comments {line: text}, code_lines, dynamic_lines).

    The body of a DO block, and the string handed to EXECUTE, is split recursively: some migrations are
    applied as ONE DO block (a tool that takes a single statement), so the DDL lives inside it."""
    out, comments, code, dyn, buf, first, i, n = [], {}, set(), [], [], None, 0, len(text)

    def put(tok):
        nonlocal first
        if tok.strip():
            code.add(line)
            first = line if first is None else first
        buf.append(tok)

    def inner(body):  # statements of a DO body / EXECUTE string, lines offset to this file
        s2, c2, k2, d2 = split_sql(body, line)
        out.extend(s2)
        comments.update(c2)
        code.update(k2)
        dyn.extend(d2)

    def runs_ddl():  # is the literal being read a DO body or the argument of EXECUTE?
        head = "".join(buf).strip()
        return bool(re.match(r"do\b", head, re.I) or re.search(r"\bexecute$", head, re.I))

    while i < n:
        c = text[i]
        if text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            comments[line] = text[i + 2:j].strip()
            i = j
        elif text.startswith("/*", i):
            depth, j = 1, i + 2  # Postgres block comments nest
            while j < n and depth:
                depth += text.startswith("/*", j) - text.startswith("*/", j)
                j += 2 if text.startswith(("/*", "*/"), j) else 1
            for k in range(line, line + text.count("\n", i, j) + 1):
                comments[k] = text[i + 2:j - 2].strip()
            line += text.count("\n", i, j)
            i = j
            buf.append(" ")
        elif c in "'\"":
            esc, j = c == "'" and text[i - 1:i] in ("e", "E") and not re.match(r"[\w$]", text[i - 2:i - 1] or " "), i + 1  # E'..' only when the e stands alone (not `else'..'`)
            while j < n:
                if esc and text[j] == "\\":
                    j += 2
                elif text[j] == c:
                    if text[j + 1:j + 2] != c:
                        break
                    j += 2
                else:
                    j += 1
            tok = text[i:j + 1]
            sql = tok[1:-1].replace("''", "'")
            if c == "'" and runs_ddl() and re.match(r"\s*(create|alter|grant|revoke)\b", sql, re.I) and "%" not in sql:
                inner(sql)
            elif c == "'" and re.match(r"\s*create\s+(unlogged\s+)?table", sql, re.I):
                dyn.append(line)
            put("''" if c == "'" else tok)
            line += tok.count("\n")
            i = j + 1
        elif c == "$" and not re.match(r"[\w$]", text[i - 1:i] or " ") and (m := re.match(r"\$([A-Za-z_]\w*)?\$", text[i:])):
            close = text.find(m.group(0), i + m.end())
            stop = n if close < 0 else close + len(m.group(0))
            body = text[i + m.end():n if close < 0 else close]
            if runs_ddl():
                inner(body)
            elif re.search(r"create\s+(?:unlogged\s+)?table", body, re.I):
                dyn.append(line)
            put(" $$ ")
            line += text.count("\n", i, stop)
            i = stop
        elif c == ";":
            if first is not None:
                out.append(("".join(buf).strip(), first, line))
            buf, first, i = [], None, i + 1
        else:
            put(c)
            line += c == "\n"
            i += 1
    if first is not None and "".join(buf).strip():
        out.append(("".join(buf).strip(), first, line))
    return out, comments, code, dyn


def apply(r, grant, roles, privs, reasoned=False):
    """Fold one GRANT/REVOKE into a relation. r["bare"] = (role, privilege) pairs held by anon/PUBLIC that
    were granted without an `anon-ok` reason; the reason belongs to the statement it sits on."""
    privs = (privs - {"all"}) | TABLE_PRIVS if "all" in privs else privs
    for role in roles:
        cur = r["g"].setdefault(role, set())
        if grant:
            cur |= privs
            if role in ("anon", "public"):
                pairs = {(role, p) for p in privs}
                if reasoned:
                    r["bare"] -= pairs
                else:
                    r["bare"] |= pairs
        else:
            cur -= privs
            r["bare"] -= {(role, p) for p in privs}


def seq_ok(table):  # does any API role hold a privilege that lets nextval() run?
    return any(p & {"usage", "update"} for p in table.values())


def seq_apply(table, grant, roles, privs):
    privs = (privs - {"all"}) | SEQ_PRIVS if "all" in privs else privs
    for role in roles & API:
        cur = table.setdefault(role, set())
        table[role] = cur | privs if grant else cur - privs


def analyse(text, schemas):
    """-> (findings [(line, relation, rule, message)], dynamic_lines, relations_checked)."""
    stmts, comments, code, dyn = split_sql(text)
    rels, seqs, seq_bulk, blanket, default = {}, {}, {}, [], "public"  # seqs: (schema, name) -> {role: privs}

    def ctx(a, b):  # the comment block directly above a statement, plus comments inside it
        above, k = [], a - 1
        while k in comments and k not in code:
            above.append(comments[k])
            k -= 1
        return " ".join(above + [comments.get(k, "") for k in range(a, b + 1)])

    def new_rel(kind, a, b, serial=()):
        return dict(kind=kind, line=a, closed=bool(NONE.search(ctx(a, b))), rls=False, g={}, bare=set(), serial=list(serial))

    for s, a, b in stmts:
        s = unwrap(s)
        if m := SEARCH.match(s):
            names = [nid(x) for x in re.findall(ID, m.group("s")) if nid(x) != "$user"]
            default = names[0] if names and names[0] != "default" else "public"
        elif m := CREATE.match(s):
            mods, kind = m.group("m").lower(), m.group("k").lower()
            sch, name = qname(m.group("n"), default)
            if "temp" in mods or sch not in schemas or re.match(r"\s*partition\s+of\b", s[m.end():], re.I):
                continue
            serial = [seq_name(name, nid(c.group("c"))) for c in SERIAL.finditer(s)] if kind == "table" else []
            rels[(sch, name)] = new_rel(kind, a, b, serial)
        elif m := SELINTO.match(s):  # SELECT ... INTO schema.t creates a table
            sch, name = qname(m.group("n"), default)
            if sch in schemas:
                rels[(sch, name)] = new_rel("table", a, b)
        elif m := MOVE.match(s):  # SET SCHEMA keeps the ACL the relation had, so a move into a guarded schema is a create
            src, to = qname(m.group("n"), default), nid(m.group("to"))
            old = rels.pop(src, None)
            if to in schemas:
                rels[(to, src[1])] = old or new_rel("table" if m.group("k").lower() == "table" else "view", a, b)
        elif m := RENAME.match(s):
            src = qname(m.group("n"), default)
            if src in rels:
                rels[(src[0], nid(m.group("to")))] = rels.pop(src)
        elif m := RLS.match(s):
            if r := rels.get(qname(m.group("n"), default)):
                r["rls"] = True
        elif m := ADP.match(s):
            body = re.sub(r"\s+", " ", m.group("b"))
            v = re.search(r"\b(grant|revoke)\b", body, re.I)
            ins = re.search(rf"\bin schema ({ID})", body, re.I)
            roles = {nid(x) for x in re.findall(ID, re.split(r"\bto\b", body, maxsplit=1, flags=re.I)[-1])} if v and v.group(1).lower() == "grant" else set()
            if roles & OPEN and (not ins or nid(ins.group(1)) in schemas):
                blanket.append((a, "ALTER DEFAULT PRIVILEGES grants to " + ", ".join(sorted(roles & OPEN)), s))
        elif (m := GRANT.match(s)) and not m.group("go"):  # `revoke grant option for` removes no privilege
            grant = m.group("v").lower() == "grant"
            privs = {w for w in re.findall(r"[a-z]+", re.sub(r"\([^)]*\)", " ", m.group("p").lower())) if w in PRIVS}
            roles = {nid(x) for x in re.findall(ID, m.group("r")) if x.lower() not in ("group", "current_user", "session_user")}
            t, reasoned = m.group("t").strip(), bool(ANON_OK.search(ctx(a, b)))
            if bulk := re.match(r"all\s+(tables|sequences|functions|procedures|routines)\s+in\s+schema\s+(.+)", t, re.I | re.S):
                what = bulk.group(1).lower()
                for sch in (nid(x) for x in re.findall(ID, bulk.group(2)) if nid(x) in schemas):
                    if grant and roles & OPEN:
                        blanket.append((a, f"GRANT ON ALL {what.upper()} IN SCHEMA {sch} to " + ", ".join(sorted(roles & OPEN)), s))
                    if what == "sequences":
                        seq_apply(seq_bulk.setdefault(sch, {}), grant, roles, privs)
                    for (rs, _), r in rels.items():
                        if what == "tables" and rs == sch:
                            apply(r, grant, roles, privs, reasoned)
            elif re.match(r"sequence\b", t, re.I):
                for x in re.findall(QN, t[8:]):
                    seq_apply(seqs.setdefault(qname(x, default), {}), grant, roles, privs)
            elif not re.match(r"(schema|database|function|procedure|routine|language|type|domain|foreign|tablespace|large|parameter)\b", t, re.I):
                for x in re.findall(QN, re.sub(r"^table\s+", "", t, flags=re.I)):
                    if r := rels.get(qname(x, default)):
                        apply(r, grant, roles, privs, reasoned)
    found = [(a, "stmt-" + hashlib.sha1(re.sub(r"\s+", " ", s.lower()).encode()).hexdigest()[:8], "G004", why) for a, why, s in blanket]
    for (sch, name), r in rels.items():
        who, a = f"{sch}.{name}", r["line"]
        if not r["closed"] and not any(r["g"].get(x) for x in API):
            found.append((a, who, "G001", f"{r['kind']} has no GRANT to anon/authenticated/service_role in this migration (or annotate `-- data-api: none (<reason>)`)"))
        if r["kind"] == "table" and not r["rls"]:
            found.append((a, who, "G002", "no ALTER TABLE ... ENABLE ROW LEVEL SECURITY in this migration"))
        held = {(role, p) for role in ("anon", "public") for p in r["g"].get(role, ())}
        if bare := sorted({f"{role}:{p}" for role, p in r["bare"] & held}):
            found.append((a, who, "G003", f"{', '.join(bare)} granted with no `-- anon-ok: <reason>` on that GRANT"))
        for sq in [] if r["closed"] else r["serial"]:
            if not seq_ok(seqs.get((sch, sq), {})) and not seq_ok(seq_bulk.get(sch, {})):
                found.append((a, who, "G005", f"serial column needs GRANT USAGE ON SEQUENCE {sch}.{sq} (identity columns do not)"))
    return found, dyn, len(rels)


def collect(paths, excludes=()):
    """-> (files after excludes, paths that matched no .sql file at all)."""
    files, empty = [], []
    for p in paths:
        got = []
        for h in glob.glob(p, recursive=True) or [p]:
            if os.path.isdir(h):
                got += [os.path.join(d, f) for d, _, fs in os.walk(h) for f in fs if f.endswith(".sql")]
            elif os.path.isfile(h):
                got.append(h)
        files += got
        if not got:
            empty.append(p)
    skip = lambda f: any(fnmatch.fnmatch("/" + os.path.normpath(f).replace(os.sep, "/"), x) for x in excludes)
    return sorted(f for f in set(files) if not skip(f)), empty


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--baseline")
    ap.add_argument("--write-baseline", action="store_true")
    ap.add_argument("--schemas", default="public", help="comma list of schemas whose new relations need grants")
    ap.add_argument("--root", default=".", help="baseline keys are file paths relative to this")
    ap.add_argument("--exclude", action="append", default=[], help="fnmatch pattern on /relative/path (tests, fixtures, rollbacks)")
    a = ap.parse_args(argv)
    if a.write_baseline and not a.baseline:
        ap.error("--write-baseline needs --baseline FILE")
    schemas, (files, empty) = {s.strip().lower() for s in a.schemas.split(",")}, collect(a.paths, a.exclude)
    if empty or not files:  # a typo in one registry path must not turn into a silent pass
        print("check-migration-grants: no .sql files matched " + " ".join(empty or a.paths), file=sys.stderr)
        return 2
    base = set()
    if a.baseline and os.path.exists(a.baseline) and not a.write_baseline:
        base = {x.strip() for x in open(a.baseline) if x.strip() and not x.startswith("#")}
    keys, new, nrel, warn = set(), [], 0, 0
    for f in files:
        rel = os.path.relpath(f, a.root).replace(os.sep, "/")
        found, dyn, n = analyse(open(f, encoding="utf-8", errors="replace").read(), schemas)
        nrel, warn = nrel + n, warn + len(dyn)
        for ln in dyn:
            print(f"{rel}:{ln}: WARN dynamic CREATE TABLE in a DO/function body is not analysed", file=sys.stderr)
        for line, who, rule, why in found:
            keys.add(key := f"{rel}|{who}|{rule}")
            if key not in base:
                new.append((rel, line, rule, who, why))
    if a.write_baseline:
        with open(a.baseline, "w") as fh:
            fh.write("# check-migration-grants baseline: findings in migrations applied before this check existed.\n"
                     "# Shrink it by fixing the follow-up migration, never by adding lines. key = file|relation|rule\n")
            fh.writelines(k + "\n" for k in sorted(keys))
        print(f"wrote {len(keys)} baseline finding(s) from {len(files)} file(s), {nrel} relation(s), to {a.baseline}")
        return 0
    for rel, line, rule, who, why in sorted(new):
        print(f"::error file={rel},line={line}::{rule} {who}: {why}" if os.environ.get("GITHUB_ACTIONS") else f"{rel}:{line}: {rule} {who}: {why}")
    print(f"check-migration-grants: {len(files)} file(s), {nrel} relation(s) in {','.join(sorted(schemas))}, {len(keys)} finding(s), {len(keys) - len(new)} baselined, {len(new)} NEW, {warn} warning(s), {len(base - keys)} stale baseline line(s)")
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main())
