#!/usr/bin/env node
// Guards public/.well-known/mcp/server-card.json against drift from the real
// MCP server: every tool registered with mcp.tool() in
// ../mcp-server/health4ai/server.py must be listed, and nothing else. The card
// must not claim a hosted serverUrl: the server is local stdio (BYOB database).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const webRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const card = JSON.parse(fs.readFileSync(path.join(webRoot, 'public/.well-known/mcp/server-card.json'), 'utf8'));
const serverPy = fs.readFileSync(path.join(webRoot, '..', 'mcp-server/health4ai/server.py'), 'utf8');
const registered = [...serverPy.matchAll(/^mcp\.tool\(\)\((\w+)\)/gm)].map((m) => m[1]).sort();

test('server.py registration list was found (guard against a vacuous pass)', () => {
  assert.ok(registered.length >= 5, `found ${registered.length} mcp.tool() registrations`);
});

test('card tools match server.py registrations exactly', () => {
  assert.deepEqual(card.tools.map((t) => t.name).sort(), registered);
});

test('every tool has a public description', () => {
  for (const t of card.tools) assert.ok(t.description && t.description.length > 20, t.name);
});

test('required identity fields present; stdio, no hosted serverUrl claimed', () => {
  for (const k of ['name', 'description', 'version']) assert.ok(card[k], k);
  assert.equal(card.serverInfo.version, card.version);
  assert.equal(card.transport.type, 'stdio');
  assert.equal(card.serverUrl, undefined);
});
