// @ts-check
// CPAP SD card reader: turns a ResMed AirSense 11 card into Samples, in the browser (cpap.html)
// and in Node (the tests). A plain ES module with JSDoc types, because public/ has no build step:
// the page imports this file as it is served, and vitest and tsc read the same file.
//
// The EDF and EDF+ parsing follows the specification at edfplus.info. Card times are the device's
// wall clock with no zone, so a parsed time is a "wall" number: milliseconds as if that wall clock
// were UTC. wallToInstant() turns one into a real instant for a chosen IANA time zone.

/**
 * @typedef {object} EdfSignal
 * @property {string} label
 * @property {string} unit
 * @property {number} physMin
 * @property {number} physMax
 * @property {number} digMin
 * @property {number} digMax
 * @property {number} samplesPerRecord
 */

/**
 * @typedef {object} EdfAnnotation
 * @property {number} onset seconds from the file's start time
 * @property {number | null} duration seconds, or null when the TAL gives none
 * @property {string} text
 */

/**
 * @typedef {object} Edf
 * @property {'EDF' | 'EDF+C' | 'EDF+D'} format
 * @property {number} startWall the header's start date and time, as wall-clock milliseconds
 * @property {number} recordSeconds
 * @property {number} recordCount
 * @property {EdfSignal[]} signals
 * @property {number[]} recordOnsets each record's start, in seconds from the file's start time
 * @property {EdfAnnotation[]} annotations every non-empty annotation, in file order
 * @property {(label: string) => number[][] | null} values a signal's physical values per record, or null when the file has no such signal
 */

const ANNOTATION_LABEL = 'EDF Annotations'
const TAL_ONSET = /^[+-]\d+(\.\d*)?$/
const TAL_DURATION = /^\d+(\.\d*)?$/

/**
 * Parses an EDF or EDF+ file. Throws on a header that is not EDF. A record cut short by the end
 * of the file is left out rather than refused; a declared record count of -1 ("unknown") is read
 * from the file length instead.
 * @param {Uint8Array} bytes
 * @returns {Edf}
 */
export function parseEdf(bytes) {
  if (bytes.length < 256) throw new Error('Not an EDF file: the header is cut short')
  const ascii = (/** @type {number} */ offset, /** @type {number} */ width) =>
    String.fromCharCode(...bytes.subarray(offset, offset + width)).trim()
  const number = (/** @type {number} */ offset, /** @type {number} */ width, /** @type {string} */ name) => {
    const text = ascii(offset, width)
    const n = Number(text)
    if (text === '' || !Number.isFinite(n)) throw new Error(`Not an EDF file: ${name} is ${JSON.stringify(text)}`)
    return n
  }

  if (ascii(0, 8) !== '0') throw new Error('Not an EDF file: the version is not 0')
  const date = ascii(168, 8).match(/^(\d\d)\.(\d\d)\.(\d\d)$/)
  const time = ascii(176, 8).match(/^(\d\d)\.(\d\d)\.(\d\d)$/)
  if (!date || !time) throw new Error('Not an EDF file: the start date or time is malformed')
  const yy = Number(date[3])
  const startWall = Date.UTC(yy >= 85 ? 1900 + yy : 2000 + yy, Number(date[2]) - 1, Number(date[1]),
    Number(time[1]), Number(time[2]), Number(time[3]))

  const headerBytes = number(184, 8, 'the header length')
  const reserved = ascii(192, 44)
  const declaredRecords = number(236, 8, 'the record count')
  const recordSeconds = number(244, 8, 'the record duration')
  const ns = number(252, 4, 'the signal count')
  if (headerBytes !== 256 + ns * 256 || bytes.length < headerBytes) {
    throw new Error('Not an EDF file: the header length does not match its signal count')
  }

  // After the fixed header, each field holds one value per signal, one field after another.
  let fieldStart = 256
  const field = (/** @type {number} */ width) => {
    const start = fieldStart
    fieldStart += ns * width
    return (/** @type {number} */ i) => start + i * width
  }
  const labelAt = field(16)
  field(80) // transducer type
  const unitAt = field(8), physMinAt = field(8), physMaxAt = field(8), digMinAt = field(8), digMaxAt = field(8)
  field(80) // prefiltering
  const samplesAt = field(8)
  /** @type {EdfSignal[]} */
  const signals = []
  for (let i = 0; i < ns; i++) {
    signals.push({
      label: ascii(labelAt(i), 16),
      unit: ascii(unitAt(i), 8),
      physMin: number(physMinAt(i), 8, 'a physical minimum'),
      physMax: number(physMaxAt(i), 8, 'a physical maximum'),
      digMin: number(digMinAt(i), 8, 'a digital minimum'),
      digMax: number(digMaxAt(i), 8, 'a digital maximum'),
      samplesPerRecord: number(samplesAt(i), 8, 'a sample count'),
    })
  }

  const recordBytes = signals.reduce((n, s) => n + s.samplesPerRecord * 2, 0)
  const available = recordBytes > 0 ? Math.floor((bytes.length - headerBytes) / recordBytes) : 0
  const recordCount = declaredRecords < 0 ? available : Math.min(declaredRecords, available)
  const offsets = signals.map((_, i) => signals.slice(0, i).reduce((n, s) => n + s.samplesPerRecord * 2, 0))
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const signalAt = (/** @type {number} */ r, /** @type {number} */ i) => headerBytes + r * recordBytes + offsets[i]

  // The first TAL of the first annotation signal in a record is that record's timestamp; plain
  // EDF records follow each other evenly.
  const annotationSignals = signals.flatMap((s, i) => (s.label === ANNOTATION_LABEL ? [i] : []))
  /** @type {number[]} */
  const recordOnsets = []
  /** @type {EdfAnnotation[]} */
  const annotations = []
  for (let r = 0; r < recordCount; r++) {
    let onset = r * recordSeconds
    annotationSignals.forEach((i, nth) => {
      const start = signalAt(r, i)
      parseTals(bytes.subarray(start, start + signals[i].samplesPerRecord * 2)).forEach((t, k) => {
        if (nth === 0 && k === 0) onset = t.onset
        for (const text of t.texts) if (text) annotations.push({ onset: t.onset, duration: t.duration, text })
      })
    })
    recordOnsets.push(onset)
  }

  const format = reserved.startsWith('EDF+C') ? 'EDF+C' : reserved.startsWith('EDF+D') ? 'EDF+D' : 'EDF'
  return {
    format, startWall, recordSeconds, recordCount, signals, recordOnsets, annotations,
    values(label) {
      const i = signals.findIndex((s) => s.label === label)
      if (i < 0) return null
      const s = signals[i]
      const out = []
      for (let r = 0; r < recordCount; r++) {
        const start = signalAt(r, i)
        const record = []
        for (let j = 0; j < s.samplesPerRecord; j++) {
          // Multiplied before dividing, so a value the file holds exactly comes out exactly.
          const digital = view.getInt16(start + j * 2, true)
          record.push(s.physMin + ((digital - s.digMin) * (s.physMax - s.physMin)) / (s.digMax - s.digMin))
        }
        out.push(record)
      }
      return out
    },
  }
}

/**
 * The TALs in one record's annotation bytes: `+onset[\x15duration]\x14[text\x14]...\x00`, the
 * unused rest of the signal being zero bytes.
 * @param {Uint8Array} bytes
 * @returns {{ onset: number, duration: number | null, texts: string[] }[]}
 */
function parseTals(bytes) {
  const utf8 = new TextDecoder('utf-8')
  const tals = []
  let start = 0
  while (start < bytes.length) {
    let end = bytes.indexOf(0, start)
    if (end < 0) end = bytes.length
    if (end > start) {
      const parts = utf8.decode(bytes.subarray(start, end)).split('\x14')
      const [onsetText, durationText] = parts[0].split('\x15')
      if (!TAL_ONSET.test(onsetText) || (durationText !== undefined && !TAL_DURATION.test(durationText))) {
        throw new Error(`Malformed EDF+ annotation: ${JSON.stringify(parts[0])}`)
      }
      // A TAL ends with \x14, so its last part is always empty.
      tals.push({ onset: Number(onsetText), duration: durationText === undefined ? null : Number(durationText), texts: parts.slice(1, -1) })
    }
    start = end + 1
  }
  return tals
}

/** @type {Map<string, Intl.DateTimeFormat>} */
const zoneFormats = new Map()

/**
 * How far `timeZone` is ahead of UTC at instant `ms`, in milliseconds. Throws a RangeError for a
 * zone the runtime does not know.
 * @param {number} ms
 * @param {string} timeZone
 */
function zoneOffset(ms, timeZone) {
  let format = zoneFormats.get(timeZone)
  if (!format) {
    format = new Intl.DateTimeFormat('en-US', {
      timeZone, hourCycle: 'h23', year: 'numeric', month: 'numeric', day: 'numeric',
      hour: 'numeric', minute: 'numeric', second: 'numeric',
    })
    zoneFormats.set(timeZone, format)
  }
  /** @type {Record<string, number>} */
  const p = {}
  for (const part of format.formatToParts(ms)) p[part.type] = Number(part.value)
  const wholeSecond = ms - (((ms % 1000) + 1000) % 1000)
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - wholeSecond
}

/**
 * The instant a wall-clock time in `timeZone` names. In the hour a clock repeats when it falls
 * back, the first occurrence; in the hour it skips when it springs forward, the time the clock
 * would show had it not jumped (02:30 becomes 03:30), so every wall time has exactly one answer.
 * @param {number} wall wall-clock milliseconds, as if the wall clock were UTC
 * @param {string} timeZone an IANA zone, e.g. "America/Toronto"
 * @returns {number} epoch milliseconds
 */
export function wallToInstant(wall, timeZone) {
  return wallToInstants(wall, timeZone)[0]
}

/**
 * Every instant a wall-clock time in `timeZone` names, earliest first: two in the hour a clock
 * repeats when it falls back, otherwise one (for a skipped time, as wallToInstant gives it).
 * @param {number} wall wall-clock milliseconds, as if the wall clock were UTC
 * @param {string} timeZone an IANA zone
 * @returns {number[]} epoch milliseconds
 */
function wallToInstants(wall, timeZone) {
  // A day either side brackets any transition near this wall time.
  const before = zoneOffset(wall - 86_400_000, timeZone)
  const after = zoneOffset(wall + 86_400_000, timeZone)
  const fits = [...new Set([before, after].map((o) => wall - o).filter((t) => t + zoneOffset(t, timeZone) === wall))]
  return fits.length ? fits.sort((a, b) => a - b) : [wall - before]
}

// ---------------------------------------------------------------------------------------------
// The card. Only STR.edf (one record a day of summary values), each session's EVE (events) and
// CSL (Cheyne-Stokes periods) files, and its PLD file (two-second trends) are read; of a PLD file
// only the leak signal is decoded, and only the leak trace leaves the browser. The BRP and SA2
// waveforms, nearly all of a card's size, are never picked, so they are never read.

/**
 * A Sample as /api/ingest and the setup API's sample upload accept it.
 * @typedef {object} Sample
 * @property {string} metric_type
 * @property {number | null} value
 * @property {string} unit
 * @property {string} source_device
 * @property {string} started_at
 * @property {string | null} ended_at
 * @property {Record<string, unknown> | null} metadata
 */

/**
 * @typedef {object} CardFile
 * @property {string} path the path relative to the picked folder, as webkitRelativePath gives it
 * @property {Uint8Array} bytes
 */

/**
 * @typedef {object} NightSummary
 * @property {string} date YYYY-MM-DD, by the noon rule
 * @property {number} sessions
 * @property {number} usageHours
 * @property {number} events
 */

/**
 * A session's leak, from its PLD file, reduced to one value per clock minute. Offsets count from
 * the file's start time, so the trace does not depend on the time zone the card is read in.
 * @typedef {object} LeakTrace
 * @property {number} startWall the file's start date and time, as wall-clock milliseconds
 * @property {number} first ms from the file's start to its first leak reading
 * @property {number} end ms from the file's start to the end of its last reading
 * @property {number} minute0 ms from the file's start to the start of the first reading's clock minute (0 or less)
 * @property {(number | null)[]} lpm per clock minute from minute0: the mean of that minute's readings in L/min, to 0.1, or null for a minute with none
 */

/**
 * A PLD file as readCard takes it: its leak trace (null for a file with no records), or why it
 * could not be read (readLeakFile).
 * @typedef {{ path: string, trace: LeakTrace | null } | { path: string, error: string }} LeakFile
 */

/**
 * @typedef {object} CardImport
 * @property {Sample[]} samples sorted by started_at, then metric_type
 * @property {NightSummary[]} nights oldest first
 * @property {{ nights: number, sessions: number, stubSessions: number, events: number, droppedEvents: number, leakMinutes: number, droppedLeakFiles: number, unreadable: { path: string, reason: string }[] }} stats
 */

export const SOURCE_DEVICE = 'AirSense 11'
/**
 * Sessions shorter than this are mask-fit checks and self-tests, not therapy: they are not counted
 * in usage and their events are dropped. On the card this was chosen against, every session was
 * either under 5 minutes or over 30.
 */
export const STUB_MINUTES = 5
/** The ingest limit per request (MAX_SAMPLES in src/ingest.ts). */
export const BATCH_SIZE = 1000

const DAY_MS = 86_400_000
const NOON_MS = 12 * 3_600_000
// STR.edf gives mask-on and mask-off to the minute, so an event is placed in a session with a
// minute's slack either side.
const SESSION_SLACK_MS = 60_000
// Case-insensitive: the card is FAT, and some tools and mounts change the case of its names.
const EVENT_FILE = /^DATALOG\/\d{8}\/\d{8}_\d{6}_(EVE|CSL)\.edf$/i
const LEAK_FILE = /^DATALOG\/\d{8}\/\d{8}_\d{6}_PLD\.edf$/i
/** A leak trace Sample covers at most this many clock minutes, so its metadata stays small. */
export const LEAK_CHUNK_MINUTES = 60

/**
 * The files a card import reads, from every path under the picked folder: the shallowest
 * STR.edf, and the EVE, CSL and PLD files in DATALOG/<YYYYMMDD>/ beside it. Nothing when there is
 * no STR.edf.
 * @param {string[]} paths
 * @returns {{ str: string | null, events: string[], leaks: string[] }}
 */
export function pickCardFiles(paths) {
  const depth = (/** @type {string} */ p) => p.split('/').length
  const isStr = (/** @type {string} */ p) => p.toLowerCase() === 'str.edf' || p.toLowerCase().endsWith('/str.edf')
  const strs = paths.filter(isStr)
  if (!strs.length) return { str: null, events: [], leaks: [] }
  const str = strs.reduce((a, b) => (depth(b) < depth(a) ? b : a))
  const root = str.slice(0, -'STR.edf'.length)
  const under = (/** @type {RegExp} */ name) => paths.filter((p) => p.startsWith(root) && name.test(p.slice(root.length)))
  return { str, events: under(EVENT_FILE), leaks: under(LEAK_FILE) }
}

/**
 * A PLD file's LeakFile: its trace, or the reason readLeakTrace refused it. The page and the script
 * read each PLD file this way, one at a time, and keep only the result.
 * @param {string} path
 * @param {Uint8Array} bytes
 * @returns {LeakFile}
 */
export function readLeakFile(path, bytes) {
  try {
    return { path, trace: readLeakTrace(bytes) }
  } catch (err) {
    return { path, error: err instanceof Error ? err.message : String(err) }
  }
}

/**
 * Reads the leak signal ("Leak.2s", or the first whose label starts with "Leak") from a PLD file
 * into a LeakTrace; no other signal is decoded. Leak is read in L/min (the AirSense 11 writes L/s);
 * a reading that is not a number is skipped. A minute's value is the mean of the readings that fall
 * in it, so a session's first and last minutes, only partly recorded, count the readings they have.
 * Returns null for a file with no records, which the device writes for a session that ends within
 * seconds. Throws on a file that is not EDF, has no leak signal, has records but no readings, or
 * gives leak in another unit.
 * @param {Uint8Array} bytes
 * @returns {LeakTrace | null}
 */
export function readLeakTrace(bytes) {
  const edf = parseEdf(bytes)
  const signal = edf.signals.find((s) => s.label === 'Leak.2s') ?? edf.signals.find((s) => s.label.toLowerCase().startsWith('leak'))
  if (!signal) throw new Error(`No leak signal (the file has ${edf.signals.map((s) => s.label).join(', ') || 'no signals'})`)
  const unit = signal.unit.trim().toLowerCase()
  const toLpm = unit === 'l/s' ? 60 : unit === 'l/min' ? 1 : null
  if (toLpm === null) throw new Error(`${signal.label} is in an unknown unit (${unit || 'none'})`)
  if (edf.recordCount === 0) return null
  const step = edf.recordSeconds / signal.samplesPerRecord * 1000
  /** @type {Map<number, { sum: number, n: number }>} by clock minute, as wall-clock ms */
  const minutes = new Map()
  let first = Infinity, end = -Infinity
  const records = /** @type {number[][]} */ (edf.values(signal.label))
  records.forEach((record, r) => {
    record.forEach((value, j) => {
      if (!Number.isFinite(value)) return
      const offset = Math.round(edf.recordOnsets[r] * 1000 + j * step)
      const minute = Math.floor((edf.startWall + offset) / 60_000) * 60_000
      const m = minutes.get(minute) ?? { sum: 0, n: 0 }
      m.sum += value * toLpm
      m.n++
      minutes.set(minute, m)
      first = Math.min(first, offset)
      end = Math.max(end, offset + step)
    })
  })
  if (!minutes.size) throw new Error(`${signal.label} has no readings`)
  const firstMinute = Math.min(...minutes.keys())
  // A corrupt record onset would otherwise size the minute array from it.
  if (Math.max(...minutes.keys()) - firstMinute > DAY_MS) throw new Error(`${signal.label} spans more than a day`)
  const count = (Math.max(...minutes.keys()) - firstMinute) / 60_000 + 1
  const lpm = Array.from({ length: count }, (_, i) => {
    const m = minutes.get(firstMinute + i * 60_000)
    return m ? Math.round(m.sum / m.n * 10) / 10 : null
  })
  return { startWall: edf.startWall, first, end: Math.round(end), minute0: firstMinute - edf.startWall, lpm }
}

/** The night a wall-clock time belongs to, by the noon rule. */
const nightOf = (/** @type {number} */ wall) => new Date(wall - NOON_MS).toISOString().slice(0, 10)
/** Drops the floating-point noise of scaling; every STR.edf value is coarser than this. */
const tidy = (/** @type {number} */ x) => Math.round(x * 1000) / 1000
/** "Obstructive Apnea" -> "obstructive_apnea": whatever the device wrote, so a new label still imports. */
const snake = (/** @type {string} */ label) => label.trim().toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '')

/**
 * Reads a card into Samples for one Person, source_device "AirSense 11":
 *
 * - One Night per STR.edf day with therapy: cpap.ahi, cpap.usage_hours, cpap.leak_p95 (L/min) and
 *   cpap.pressure_median (mask pressure, cmH2O), each from the night's first mask-on to its last
 *   mask-off. Those instants come from STR.edf, which keeps its history, so a later card that
 *   covers the same night gives the same started_at and the upload overwrites rather than adds.
 * - One cpap.event.<type> per EVE event (value: its duration in seconds), and one cpap.event.csr
 *   per CSL "CSR Start"/"CSR End" pair. An event is kept only if it starts inside one of its
 *   Night's sessions.
 * - The leak trace of each session whose PLD file starts inside one of its Night's sessions, as
 *   cpap.leak_trace Samples of up to LEAK_CHUNK_MINUTES clock minutes each (value: their mean in
 *   L/min; metadata.minute0 is the first minute's start and metadata.lpm the minute values). The
 *   first starts at the session's first reading and later ones on a minute, so sessions that
 *   share a clock minute never share a started_at.
 *
 * ResMed writes an event's onset when the event ends, with its duration reaching back: during the
 * seconds before each onset, a card's own flow waveform is flat for nearly every apnea, and the
 * seconds after it are not. So started_at is onset minus duration and ended_at is the onset.
 *
 * Times are the device's wall clock, made instants in `timeZone`; import a card with the same zone
 * every time, or the same Night lands at another started_at and is stored twice. A file that cannot
 * be parsed is listed in stats.unreadable and skipped; an STR.edf that cannot is an error.
 * @param {{ str: Uint8Array, events: CardFile[], leaks?: LeakFile[] }} card
 * @param {{ timeZone: string }} options
 * @returns {CardImport}
 */
export function readCard(card, { timeZone }) {
  wallToInstant(0, timeZone) // an unknown zone fails here, before any work
  // Only the clock times the device writes (each STR record's noon, each EVE/CSL file's start) are
  // wall times; everything measured from them is elapsed time (EDF onsets are seconds after the
  // start), so it is added to the real instant. Clock changes then never shift or reorder times.
  const instant = (/** @type {number} */ wall) => wallToInstant(wall, timeZone)
  const iso = (/** @type {number} */ ms) => new Date(ms).toISOString()

  const str = parseEdf(card.str)
  if (str.recordSeconds !== DAY_MS / 1000) throw new Error('STR.edf does not hold one record a day')
  const signal = (/** @type {string} */ label) => {
    const values = str.values(label)
    if (!values) throw new Error(`STR.edf has no ${label} signal`)
    return values
  }
  const maskOn = signal('MaskOn'), maskOff = signal('MaskOff'), ahi = signal('AHI')
  const leak = signal('Leak.95'), pressure = signal('MaskPress.50')
  /** @type {{ path: string, reason: string }[]} */
  const unreadable = []
  // Leak is read in L/min; the AirSense 11 writes Leak.95 in L/s. Any other unit is not guessed at.
  const leakUnit = str.signals.find((s) => s.label === 'Leak.95')?.unit.trim().toLowerCase()
  const leakToLpm = leakUnit === 'l/s' ? 60 : leakUnit === 'l/min' ? 1 : null
  if (leakToLpm === null) unreadable.push({ path: 'STR.edf', reason: `Leak.95 is in an unknown unit (${leakUnit || 'none'}); leak skipped` })

  /** @typedef {{ date: string, record: number, sessions: { on: number, off: number }[], events: number }} Night */
  /** @type {Map<string, Night>} */
  const nights = new Map()
  let stubSessions = 0
  for (let r = 0; r < str.recordCount; r++) {
    // Each record runs from noon, so its date is its Night's; mask times are minutes from then.
    const noonWall = str.startWall + str.recordOnsets[r] * 1000
    const noon = instant(noonWall)
    const sessions = []
    for (let i = 0; i < maskOn[r].length; i++) {
      const on = maskOn[r][i], off = maskOff[r][i]
      // -1 marks an unused slot; a value that is not a number (no scale in the header) is none either.
      if (!Number.isFinite(on) || !Number.isFinite(off) || on < 0 || off < on) continue
      if (off - on < STUB_MINUTES) { stubSessions++; continue }
      sessions.push({ on: noon + on * 60_000, off: noon + off * 60_000 })
    }
    if (sessions.length) nights.set(nightOf(noonWall), { date: nightOf(noonWall), record: r, sessions, events: 0 })
  }

  const sessionAt = (/** @type {Night} */ n, /** @type {number} */ ms) =>
    n.sessions.find((s) => ms >= s.on - SESSION_SLACK_MS && ms <= s.off + SESSION_SLACK_MS)
  const inSession = (/** @type {Night} */ n, /** @type {number} */ ms) => sessionAt(n, ms) !== undefined
  // A file's start is a wall time; in the hour a clock repeats it names two instants, and the one
  // where the file's first reading falls inside one of its Night's sessions is the right one.
  const placed = (/** @type {number} */ wall, /** @type {Night | undefined} */ n, /** @type {number} */ firstMs) => {
    const candidates = wallToInstants(wall, timeZone)
    return (n && candidates.find((t) => inSession(n, t + firstMs))) ?? candidates[0]
  }

  /** @type {Sample[]} */
  const samples = []
  let droppedEvents = 0
  for (const file of card.events) {
    let edf
    try {
      edf = parseEdf(file.bytes)
    } catch (err) {
      unreadable.push({ path: file.path, reason: /** @type {Error} */ (err).message })
      continue
    }
    const night = nights.get(nightOf(edf.startWall))
    const fileStart = placed(edf.startWall, night, 0)
    /** @type {Map<string, number>} "CSR Start" waiting for its "CSR End", by "CSR" */
    const open = new Map()
    for (const a of edf.annotations) {
      if (a.text === 'Recording starts') continue
      const at = fileStart + a.onset * 1000
      const marker = a.text.match(/^(.+) (Start|End)$/)
      let label, start, end, value
      if (marker?.[2] === 'Start') {
        if (open.has(marker[1])) droppedEvents++
        open.set(marker[1], at)
        continue
      } else if (marker) {
        start = open.get(marker[1])
        open.delete(marker[1])
        if (start === undefined) { droppedEvents++; continue }
        label = marker[1]
        end = at
        value = (end - start) / 1000
      } else {
        label = a.text
        value = a.duration
        end = at
        start = at - (a.duration ?? 0) * 1000
      }
      const type = snake(label)
      if (!type || !night || !inSession(night, start)) {
        droppedEvents++
        continue
      }
      night.events++
      samples.push({
        metric_type: `cpap.event.${type}`, value, unit: 's', source_device: SOURCE_DEVICE,
        started_at: iso(start), ended_at: iso(end), metadata: { night: night.date, label },
      })
    }
    droppedEvents += open.size
  }

  let leakMinutes = 0, droppedLeakFiles = 0
  for (const file of card.leaks ?? []) {
    if ('error' in file) {
      unreadable.push({ path: file.path, reason: file.error })
      continue
    }
    const t = file.trace
    if (!t) { droppedLeakFiles++; continue } // no records: a session that ended within seconds
    const night = nights.get(nightOf(t.startWall))
    const fileStart = placed(t.startWall, night, t.first)
    const session = night && sessionAt(night, fileStart + t.first)
    if (!night || !session) { droppedLeakFiles++; continue } // a mask check, or a Night without therapy
    // The device can record for minutes after STR's mask-off; leak then is the mask lying off, not
    // therapy, so the trace ends where an event would stop counting.
    const end = Math.min(t.end, session.off + SESSION_SLACK_MS - fileStart)
    const kept = t.lpm.slice(0, Math.max(0, Math.ceil((end - t.minute0) / 60_000)))
    for (let k = 0; k < kept.length; k += LEAK_CHUNK_MINUTES) {
      const lpm = kept.slice(k, k + LEAK_CHUNK_MINUTES)
      const known = /** @type {number[]} */ (lpm.filter((v) => v !== null))
      if (!known.length) continue
      leakMinutes += known.length
      const minute0 = t.minute0 + k * 60_000
      samples.push({
        metric_type: 'cpap.leak_trace', value: Math.round(known.reduce((a, b) => a + b, 0) / known.length * 10) / 10,
        unit: 'L/min', source_device: SOURCE_DEVICE,
        started_at: iso(fileStart + (k === 0 ? t.first : minute0)),
        ended_at: iso(fileStart + Math.min(end, minute0 + LEAK_CHUNK_MINUTES * 60_000)),
        metadata: { night: night.date, minute0: iso(fileStart + minute0), lpm },
      })
    }
  }

  const summaries = [...nights.values()].sort((a, b) => (a.date < b.date ? -1 : 1))
  const usageHours = (/** @type {Night} */ n) => tidy(n.sessions.reduce((ms, s) => ms + s.off - s.on, 0) / 3_600_000)
  for (const n of summaries) {
    const r = n.record
    // First mask-on and last mask-off, whatever order the device filled its slots in.
    const at = {
      source_device: SOURCE_DEVICE, metadata: { night: n.date },
      started_at: iso(Math.min(...n.sessions.map((s) => s.on))), ended_at: iso(Math.max(...n.sessions.map((s) => s.off))),
    }
    const nightly = [
      { metric_type: 'cpap.ahi', value: tidy(ahi[r][0]), unit: 'events/h', ...at },
      { metric_type: 'cpap.usage_hours', value: usageHours(n), unit: 'h', ...at },
      ...(leakToLpm === null ? [] : [{ metric_type: 'cpap.leak_p95', value: tidy(leak[r][0] * leakToLpm), unit: 'L/min', ...at }]),
      { metric_type: 'cpap.pressure_median', value: tidy(pressure[r][0]), unit: 'cmH2O', ...at },
    ]
    // A signal whose header gives no scale (digital min = max) reads as NaN: leave it out rather
    // than upload a null.
    samples.push(...nightly.filter((sample) => Number.isFinite(sample.value)))
  }

  const key = (/** @type {Sample} */ s) => [s.started_at, s.metric_type, s.ended_at ?? '', String(s.value)]
  samples.sort((a, b) => {
    const ka = key(a), kb = key(b)
    for (let i = 0; i < ka.length; i++) if (ka[i] !== kb[i]) return ka[i] < kb[i] ? -1 : 1
    return 0
  })
  const events = summaries.reduce((n, s) => n + s.events, 0)
  return {
    samples,
    nights: summaries.map((n) => ({ date: n.date, sessions: n.sessions.length, usageHours: usageHours(n), events: n.events })),
    stats: {
      nights: summaries.length, sessions: summaries.reduce((n, s) => n + s.sessions.length, 0),
      stubSessions, events, droppedEvents, leakMinutes, droppedLeakFiles, unreadable,
    },
  }
}

/**
 * Uploads Samples in batches of BATCH_SIZE, one request at a time: the setup API allows 30
 * requests a minute, and a year of nights with their events is a handful of batches. A 429 waits a
 * minute and resends the same batch, up to three tries. Any other failure stops the upload with
 * the server's message; the batches already sent stay stored, and sending them again is harmless.
 * @param {Sample[]} samples
 * @param {{
 *   post: (batch: Sample[]) => Promise<{ ok: boolean, status: number, json(): Promise<any> }>,
 *   wait?: (ms: number) => Promise<void>,
 *   onProgress?: (sent: number, total: number) => void,
 * }} io
 * @returns {Promise<{ inserted: number, batches: number }>}
 */
export async function uploadSamples(samples, { post, wait = (ms) => new Promise((r) => setTimeout(r, ms)), onProgress }) {
  let inserted = 0
  let batches = 0
  for (let i = 0; i < samples.length; i += BATCH_SIZE) {
    const batch = samples.slice(i, i + BATCH_SIZE)
    for (let tries = 1; ; tries++) {
      const res = await post(batch)
      if (res.status === 429 && tries < 3) {
        await wait(60_000)
        continue
      }
      const body = await res.json().catch(() => ({}))
      if (res.status === 429) throw new Error('Too many requests. Wait a minute and upload again; nothing is stored twice.')
      if (!res.ok) throw new Error(body.error || `Upload failed (${res.status})`)
      inserted += body.inserted ?? 0
      break
    }
    batches++
    onProgress?.(i + batch.length, samples.length)
  }
  return { inserted, batches }
}
