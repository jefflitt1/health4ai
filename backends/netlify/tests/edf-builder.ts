// Builds EDF and EDF+ files byte by byte from the specification (edfplus.info), so the CPAP
// reader's tests can state their expected values from how the bytes were made. Header: 256 bytes,
// then 256 bytes per signal, every field left-aligned ASCII padded with spaces. Data: each record
// holds every signal's samples in turn, as 2-byte little-endian two's complement integers. An EDF+
// "EDF Annotations" signal carries TALs: `+onset[\x15duration]\x14text\x14...\x00`.

export interface BuiltSignal {
  label: string
  unit?: string
  physMin: number
  physMax: number
  digMin: number
  digMax: number
  samplesPerRecord: number
}

export interface BuiltEdf {
  /** dd.mm.yy */
  startDate: string
  /** hh.mm.ss */
  startTime: string
  /** '' for plain EDF, or 'EDF+C' / 'EDF+D'. */
  reserved?: string
  recordSeconds: number
  /** Written into the header; defaults to records.length. -1 means "unknown". */
  declaredRecords?: number
  recording?: string
  signals: BuiltSignal[]
  /** Per record, per signal: digital samples, or TAL bytes for an annotation signal. */
  records: (number[] | Uint8Array)[][]
}

const field = (value: string | number, width: number) => {
  const text = String(value)
  if (text.length > width) throw new Error(`${text} does not fit in ${width} bytes`)
  return text.padEnd(width, ' ')
}

export function buildEdf(f: BuiltEdf): Uint8Array {
  const ns = f.signals.length
  let header =
    field('0', 8) + field('X X X X', 80) + field(f.recording ?? 'Startdate X X X X', 80) +
    field(f.startDate, 8) + field(f.startTime, 8) + field(256 + ns * 256, 8) + field(f.reserved ?? '', 44) +
    field(f.declaredRecords ?? f.records.length, 8) + field(f.recordSeconds, 8) + field(ns, 4)
  const each = (pick: (s: BuiltSignal) => string | number, width: number) => {
    for (const s of f.signals) header += field(pick(s), width)
  }
  each((s) => s.label, 16)
  each(() => '', 80)
  each((s) => s.unit ?? '', 8)
  each((s) => s.physMin, 8)
  each((s) => s.physMax, 8)
  each((s) => s.digMin, 8)
  each((s) => s.digMax, 8)
  each(() => '', 80)
  each((s) => s.samplesPerRecord, 8)
  each(() => '', 32)

  const recordBytes = f.signals.reduce((n, s) => n + s.samplesPerRecord * 2, 0)
  const out = new Uint8Array(header.length + recordBytes * f.records.length)
  for (let i = 0; i < header.length; i++) out[i] = header.charCodeAt(i)
  const view = new DataView(out.buffer)
  let offset = header.length
  for (const record of f.records) {
    f.signals.forEach((s, i) => {
      const data = record[i]
      if (data instanceof Uint8Array) {
        if (data.length > s.samplesPerRecord * 2) throw new Error('annotations overflow their signal')
        out.set(data, offset) // the rest stays zero, which is the TAL padding
      } else {
        if (data.length !== s.samplesPerRecord) throw new Error(`${s.label} needs ${s.samplesPerRecord} samples`)
        data.forEach((v, j) => view.setInt16(offset + j * 2, v, true))
      }
      offset += s.samplesPerRecord * 2
    })
  }
  return out
}

/** One TAL: onset and optional duration in seconds as written, then its annotation texts. */
export function tal(onset: string, duration: string | null, ...texts: string[]): Uint8Array {
  const head = onset + (duration === null ? '' : '\x15' + duration) + '\x14'
  const body = texts.length ? texts.map((t) => t + '\x14').join('') : '\x14'
  return new TextEncoder().encode(head + body + '\x00')
}

export function concat(...parts: Uint8Array[]): Uint8Array {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let offset = 0
  for (const p of parts) {
    out.set(p, offset)
    offset += p.length
  }
  return out
}

/** The annotation signal as ResMed writes it in EVE and CSL files: 31 samples (62 bytes) a record. */
export const ANNOTATIONS: BuiltSignal = {
  label: 'EDF Annotations', physMin: -32768, physMax: 32767, digMin: -32768, digMax: 32767, samplesPerRecord: 31,
}
