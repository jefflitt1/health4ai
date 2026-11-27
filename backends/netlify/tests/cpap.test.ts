// The CPAP card reader in public/cpap.js, on synthetic EDF and EDF+ files built byte by byte from
// the specification (tests/edf-builder.ts). Expected values come from how each file was built:
// physical = physMin + (digital - digMin) * (physMax - physMin) / (digMax - digMin), TAL onsets
// count from the header's start time, and two-digit years 85-99 are 19xx, 00-84 are 20xx. Time
// zone expectations come from the US rules (DST from the second Sunday of March to the first
// Sunday of November), not from the code. The card layout (STR.edf records running noon to noon,
// MaskOn/MaskOff in minutes from that noon with -1 for an unused slot, an event's onset marking its
// end) is the one a real AirSense 11 card shows; every value in these files is made up.

import { describe, expect, test } from 'vitest'
import { parseEdf, pickCardFiles, readCard, readCardClock, readLeakTrace, sameClock, uploadSamples, wallToInstant } from '../public/cpap.js'
import { ANNOTATIONS, buildEdf, concat, tal } from './edf-builder.ts'

describe('EDF', () => {
  const signals = [
    { label: 'AHI', physMin: 0, physMax: 240, digMin: 0, digMax: 2400, samplesPerRecord: 1 },
    { label: 'BlowPress.95', unit: 'cmH2O', physMin: -10, physMax: 45, digMin: -500, digMax: 2250, samplesPerRecord: 2 },
  ]
  const file = () => buildEdf({
    startDate: '10.01.24', startTime: '12.00.00', recordSeconds: 86400, signals,
    records: [[[123], [-250, 2250]], [[0], [-500, 0]]],
  })

  test('reads the header and scales digital samples to physical values', () => {
    const edf = parseEdf(file())
    expect(edf.format).toBe('EDF')
    expect(edf.startWall).toBe(Date.UTC(2024, 0, 10, 12, 0, 0))
    expect(edf.recordSeconds).toBe(86400)
    expect(edf.recordCount).toBe(2)
    expect(edf.signals.map((s) => [s.label, s.unit, s.samplesPerRecord])).toEqual([['AHI', '', 1], ['BlowPress.95', 'cmH2O', 2]])
    expect(edf.values('AHI')).toEqual([[12.3], [0]])
    expect(edf.values('BlowPress.95')).toEqual([[-5, 45], [-10, 0]])
    expect(edf.values('Leak.95')).toBeNull()
    expect(edf.recordOnsets).toEqual([0, 86400])
    expect(edf.annotations).toEqual([])
  })

  test('an unknown record count (-1) is taken from the file length', () => {
    const bytes = buildEdf({
      startDate: '10.01.24', startTime: '12.00.00', recordSeconds: 60, declaredRecords: -1, signals,
      records: [[[1], [0, 0]], [[2], [0, 0]], [[3], [0, 0]]],
    })
    expect(parseEdf(bytes).values('AHI')).toEqual([[0.1], [0.2], [0.3]])
  })

  test('a record cut short at the end of the file is left out', () => {
    const bytes = file()
    expect(parseEdf(bytes.subarray(0, bytes.length - 1)).recordCount).toBe(1)
  })

  test.each([['99', 1999], ['85', 1985], ['84', 2084], ['00', 2000]])('year %s is %d', (yy, year) => {
    const edf = parseEdf(buildEdf({ startDate: `31.12.${yy}`, startTime: '23.59.58', recordSeconds: 1, signals, records: [] }))
    expect(edf.startWall).toBe(Date.UTC(year, 11, 31, 23, 59, 58))
  })

  test.each([
    ['too short', new Uint8Array(100)],
    ['not version 0', (() => { const b = file(); b[0] = 0x31; return b })()],
    ['a header length that does not match its signal count', (() => { const b = file(); b[184] = 0x39; return b })()],
  ])('%s is refused', (_name, bytes) => {
    expect(() => parseEdf(bytes)).toThrow(/EDF/)
  })

  test('a file that ends inside its signal headers is called cut short', () => {
    expect(() => parseEdf(file().slice(0, 300))).toThrow('Not an EDF file: the header is cut short')
  })
})

describe('EDF+ annotations', () => {
  const eve = (records: Uint8Array[], reserved = 'EDF+D') => buildEdf({
    startDate: '10.01.24', startTime: '23.00.30', reserved, recordSeconds: 0,
    signals: [ANNOTATIONS, { label: 'Crc16', physMin: -32768, physMax: 32767, digMin: -32768, digMax: 32767, samplesPerRecord: 1 }],
    records: records.map((r) => [r, [0]]),
  })

  test('EDF+D: each record\'s first TAL is its timestamp; the rest are annotations from the file start', () => {
    const edf = parseEdf(eve([
      concat(tal('+0', null), tal('+0', '0', 'Recording starts')),
      concat(tal('+3600', null), tal('+12.5', '30', 'Obstructive Apnea')),
      concat(tal('+7200', null), tal('+7300', null, 'Hypopnea', 'Arousal'), tal('-2', '1.5', 'Central Apnea')),
    ]))
    expect(edf.format).toBe('EDF+D')
    expect(edf.recordOnsets).toEqual([0, 3600, 7200])
    expect(edf.annotations).toEqual([
      { onset: 0, duration: 0, text: 'Recording starts' },
      { onset: 12.5, duration: 30, text: 'Obstructive Apnea' },
      { onset: 7300, duration: null, text: 'Hypopnea' },
      { onset: 7300, duration: null, text: 'Arousal' },
      { onset: -2, duration: 1.5, text: 'Central Apnea' },
    ])
  })

  test('EDF+C reads the same way', () => {
    const edf = parseEdf(eve([concat(tal('+0', null), tal('+5', '10', 'CSR Start'))], 'EDF+C'))
    expect(edf.format).toBe('EDF+C')
    expect(edf.annotations).toEqual([{ onset: 5, duration: 10, text: 'CSR Start' }])
  })

  test('annotation text is UTF-8', () => {
    const edf = parseEdf(eve([concat(tal('+0', null), tal('+1', null, 'Apnée'))]))
    expect(edf.annotations[0].text).toBe('Apnée')
  })

  test('a malformed onset is refused', () => {
    expect(() => parseEdf(eve([concat(tal('+0', null), tal('12', null, 'no sign'))]))).toThrow(/annotation/)
  })
})

describe('device wall clock to UTC', () => {
  const wall = (y: number, mo: number, d: number, h: number, mi: number) => Date.UTC(y, mo - 1, d, h, mi)
  const iso = (ms: number) => new Date(ms).toISOString()

  test.each([
    ['winter (EST, -5)', wall(2026, 1, 15, 23, 0), '2026-01-16T04:00:00.000Z'],
    ['summer (EDT, -4)', wall(2026, 7, 15, 23, 0), '2026-07-16T03:00:00.000Z'],
    ['the repeated hour takes its first occurrence (EDT)', wall(2026, 11, 1, 1, 30), '2026-11-01T05:30:00.000Z'],
    ['the skipped hour moves forward (02:30 is 03:30 EDT)', wall(2026, 3, 8, 2, 30), '2026-03-08T07:30:00.000Z'],
  ])('%s', (_name, w, expected) => {
    expect(iso(wallToInstant(w, 'America/Toronto'))).toBe(expected)
  })

  test('UTC is the identity, seconds and milliseconds included', () => {
    expect(wallToInstant(Date.UTC(2026, 0, 1, 0, 0, 7, 500), 'UTC')).toBe(Date.UTC(2026, 0, 1, 0, 0, 7, 500))
  })

  test('an unknown time zone is refused', () => {
    expect(() => wallToInstant(0, 'Mars/Olympus')).toThrow(RangeError)
  })

  // A fixed offset from UTC, as an AirSense 11 keeps its clock: the same offset all year.
  test.each([
    ['-05:00 in summer stays -5', wall(2026, 7, 15, 23, 0), '-05:00', '2026-07-16T04:00:00.000Z'],
    ['-05:00 in winter', wall(2026, 1, 15, 23, 0), '-05:00', '2026-01-16T04:00:00.000Z'],
    ['-05:00 in the hour Toronto repeats', wall(2026, 11, 1, 1, 30), '-05:00', '2026-11-01T06:30:00.000Z'],
    ['+05:30', wall(2026, 7, 15, 23, 0), '+05:30', '2026-07-15T17:30:00.000Z'],
    ['+00:00', wall(2026, 7, 15, 23, 0), '+00:00', '2026-07-15T23:00:00.000Z'],
  ])('fixed offset: %s', (_name, w, offset, expected) => {
    expect(iso(wallToInstant(w, offset))).toBe(expected)
  })

  test.each(['-5:00', '-0500', '+15:00', '-05:60', '05:00'])('a malformed offset %s is refused', (offset) => {
    expect(() => wallToInstant(0, offset)).toThrow(RangeError)
  })
})

describe('whether two clocks are the same', () => {
  // +00:00 and -00:00 are both UTC (ISO 8601 spells the same offset either way), as are UTC, Etc/UTC
  // and GMT; US/Eastern is the IANA alias of America/New_York. -05:00 and America/Toronto differ in
  // daylight time, so they are not one clock.
  test.each([
    ['+00:00', '-00:00', true], ['-05:00', '-05:00', true], ['America/Toronto', 'America/Toronto', true],
    ['+00:00', 'UTC', true], ['Etc/UTC', '-00:00', true], ['GMT', 'UTC', true], ['US/Eastern', 'America/New_York', true],
    ['-05:00', '+05:00', false], ['-05:00', 'America/Toronto', false], ['America/Toronto', 'America/New_York', false],
    ['+99:00', '-99:00', false], ['Nowhere', 'Elsewhere', false],
  ])('%s and %s: %s', (a, b, same) => {
    expect(sameClock(a, b)).toBe(same)
  })
})

describe('the machine clock from the card settings', () => {
  const settings = (featureProfiles: unknown) => new TextEncoder().encode(JSON.stringify({
    FlowGenerator: { SettingProfiles: { Attributes: { AppliedDateTime: '2026-06-12T04:24:29.707Z' }, FeatureProfiles: featureProfiles } },
  }))

  test('TimeZoneOffset is the machine clock', () => {
    expect(readCardClock(settings({ TimeZoneFeature: { TimeZoneOffset: '-05:00' } }))).toBe('-05:00')
  })

  test('no TimeZoneOffset gives none', () => {
    expect(readCardClock(settings({ AutoRampFeature: { RampTime: 10 } }))).toBeNull()
  })

  test('a settings file that is not JSON is refused, not read as having no clock', () => {
    expect(() => readCardClock(new TextEncoder().encode('{"FlowGenerator": {"Setting'))).toThrow(/CurrentSettings\.json/)
  })

  test('the TimeZoneFeature\'s offset wins over a stale one elsewhere', () => {
    expect(readCardClock(settings({ Old: { TimeZoneOffset: '-06:00' }, TimeZoneFeature: { TimeZoneOffset: '-05:00' } }))).toBe('-05:00')
  })

  test('two TimeZoneOffsets that disagree, neither the TimeZoneFeature\'s, are refused; the same one twice is fine', () => {
    expect(() => readCardClock(settings({ Old: { TimeZoneOffset: '-06:00' }, Other: { TimeZoneOffset: '-05:00' } }))).toThrow(/-06:00.*-05:00/)
    expect(readCardClock(settings({ Old: { TimeZoneOffset: '-05:00' }, TimeZoneFeature: { TimeZoneOffset: '-05:00' } }))).toBe('-05:00')
  })

  test('a TimeZoneOffset left null (a disabled profile) is passed over for the real one', () => {
    expect(readCardClock(settings({ Old: { TimeZoneOffset: null }, TimeZoneFeature: { TimeZoneOffset: '+01:00' } }))).toBe('+01:00')
    expect(readCardClock(settings({ Old: { TimeZoneOffset: null } }))).toBeNull()
  })

  test('a TimeZoneOffset that is not ±HH:MM is refused by name, never guessed at', () => {
    expect(() => readCardClock(settings({ TimeZoneFeature: { TimeZoneOffset: 'EST' } }))).toThrow(/TimeZoneOffset/)
  })
})

describe('picking files from the card', () => {
  test('STR.edf and the DATALOG EVE, CSL and PLD files beside it, never the BRP or SA2 waveforms', () => {
    const picked = pickCardFiles([
      'AirSense11/Identification.json',
      'AirSense11/STR.edf',
      'AirSense11/SETTINGS/CurrentSettings.json',
      'AirSense11/DATALOG/20240110/20240110_230030_EVE.edf',
      'AirSense11/DATALOG/20240110/20240110_230030_CSL.edf',
      'AirSense11/DATALOG/20240110/20240110_230038_BRP.edf',
      'AirSense11/DATALOG/20240110/20240110_230038_PLD.edf',
      'AirSense11/DATALOG/20240110/20240110_230038_SA2.edf',
      'AirSense11/DATALOG/20240110/._20240110_230030_EVE.edf',
      'AirSense11/DATALOG/20240110/notes_EVE.edf',
      'AirSense11/DATALOG/2024011/20240110_230030_EVE.edf',
      'AirSense11/Backup/STR.edf',
      'AirSense11/Backup/SETTINGS/CurrentSettings.json',
      'Other/DATALOG/20240110/20240110_230030_EVE.edf',
    ])
    expect(picked).toEqual({
      str: 'AirSense11/STR.edf',
      settings: 'AirSense11/SETTINGS/CurrentSettings.json',
      events: ['AirSense11/DATALOG/20240110/20240110_230030_EVE.edf', 'AirSense11/DATALOG/20240110/20240110_230030_CSL.edf'],
      leaks: ['AirSense11/DATALOG/20240110/20240110_230038_PLD.edf'],
    })
  })

  test('names in another case are picked too (the card is FAT)', () => {
    expect(pickCardFiles(['CARD/STR.EDF', 'CARD/DATALOG/20240110/20240110_230030_eve.EDF', 'CARD/DATALOG/20240110/20240110_230038_BRP.EDF',
      'CARD/DATALOG/20240110/20240110_230038_pld.EDF', 'CARD/settings/currentsettings.JSON']))
      .toEqual({ str: 'CARD/STR.EDF', settings: 'CARD/settings/currentsettings.JSON', events: ['CARD/DATALOG/20240110/20240110_230030_eve.EDF'], leaks: ['CARD/DATALOG/20240110/20240110_230038_pld.EDF'] })
  })

  test('works when the card itself is the root', () => {
    expect(pickCardFiles(['DATALOG/20240110/20240110_230030_EVE.edf', 'STR.edf']))
      .toEqual({ str: 'STR.edf', settings: null, events: ['DATALOG/20240110/20240110_230030_EVE.edf'], leaks: [] })
  })

  test('no STR.edf means nothing is picked', () => {
    expect(pickCardFiles(['AirSense11/DATALOG/20240110/20240110_230030_EVE.edf'])).toEqual({ str: null, settings: null, events: [], leaks: [] })
  })
})

describe('leak from a PLD file', () => {
  // Two-second readings, 30 a 60-second record, as the AirSense 11's PLD trends are written. Leak
  // runs 0-2 L/s over digital 0-100, so digital d is d * 0.02 L/s = d * 1.2 L/min.
  const leak = (unit = 'L/s', label = 'Leak.2s', digMax = 100) => ({ label, unit, physMin: 0, physMax: 2, digMin: 0, digMax, samplesPerRecord: 30 })
  const press = { label: 'MaskPress.2s', unit: 'cmH2O', physMin: 0, physMax: 40, digMin: 0, digMax: 2000, samplesPerRecord: 30 }
  const fifteen = (d: number) => Array(15).fill(d)
  const pld = (signal = leak()) => buildEdf({
    startDate: '10.01.24', startTime: '23.00.30', recordSeconds: 60, signals: [press, signal],
    records: [
      [Array(30).fill(500), [...fifteen(10), ...fifteen(20)]], // 23:00:30-23:00:58 at 12, 23:01:00-23:01:28 at 24
      [Array(30).fill(500), [...fifteen(30), ...fifteen(20)]], // 23:01:30-23:01:58 at 36, 23:02:00-23:02:28 at 24
      [Array(30).fill(500), [...fifteen(25), ...fifteen(5)]], // 23:02:30-23:02:58 at 30, 23:03:00-23:03:28 at 6
    ],
  })

  test('one mean per clock minute, in L/min, offsets from the file start', () => {
    // 23:00 has 15 readings at 12; 23:01 has 15 at 24 and 15 at 36; 23:02 has 15 at 24 and 15 at 30; 23:03 has 15 at 6.
    expect(readLeakTrace(pld())).toEqual({
      startWall: Date.UTC(2024, 0, 10, 23, 0, 30), first: 0, end: 180_000, minute0: -30_000, lpm: [12, 30, 27, 6],
    })
  })

  test('leak in L/min is kept as is; another label starting with Leak is read too', () => {
    expect(readLeakTrace(pld(leak('L/min')))?.lpm).toEqual([0.2, 0.5, 0.5, 0.1])
    expect(readLeakTrace(pld(leak('L/s', 'Leak')))?.lpm).toEqual([12, 30, 27, 6])
  })

  test('no leak signal, an unknown unit, or no readings is refused by name', () => {
    expect(() => readLeakTrace(buildEdf({ startDate: '10.01.24', startTime: '23.00.30', recordSeconds: 60, signals: [press], records: [] })))
      .toThrow('No leak signal (the file has MaskPress.2s)')
    expect(() => readLeakTrace(pld(leak('cfm')))).toThrow('Leak.2s is in an unknown unit (cfm)')
    // No scale (digital min = max): every reading is not a number.
    expect(() => readLeakTrace(pld(leak('L/s', 'Leak.2s', 0)))).toThrow('Leak.2s has no readings')
  })

  test('a record onset more than a day from the first is refused, not allocated', () => {
    // EDF+D: each record carries its own onset in a TAL. A second record 10^9 s on is corrupt.
    const edf = buildEdf({
      startDate: '10.01.24', startTime: '23.00.30', recordSeconds: 60, reserved: 'EDF+D', signals: [press, leak(), ANNOTATIONS],
      records: [[Array(30).fill(500), [...fifteen(10), ...fifteen(10)], tal('+0', null)], [Array(30).fill(500), [...fifteen(10), ...fifteen(10)], tal('+1000000000', null)]],
    })
    expect(() => readLeakTrace(edf)).toThrow('Leak.2s spans more than a day')
  })

  test('a file with no records is no trace, not an error', () => {
    // As the AirSense 11 writes a session that ends within seconds: the header, and a record count of 0.
    expect(readLeakTrace(buildEdf({ startDate: '10.01.24', startTime: '23.00.30', recordSeconds: 60, signals: [press, leak()], records: [] }))).toBeNull()
  })

  test('a file whose declared records were cut off is an error, not an empty file', () => {
    // One record declared; the copy stopped after the 768-byte header (256 + 2 signals x 256).
    const whole = buildEdf({ startDate: '10.01.24', startTime: '23.00.30', recordSeconds: 60, signals: [press, leak()],
      records: [[Array(30).fill(500), [...fifteen(10), ...fifteen(10)]]] })
    expect(() => readLeakTrace(whole.slice(0, 768))).toThrow('Leak.2s is cut off before its first record')
  })

  test('a file with an unknown record count (-1) and no records after the header is empty', () => {
    // EDF writes -1 while a recording is still open; nothing was recorded yet.
    expect(readLeakTrace(buildEdf({ startDate: '10.01.24', startTime: '23.00.30', recordSeconds: 60, declaredRecords: -1,
      signals: [press, leak()], records: [] }))).toBeNull()
  })

  test('a file with an unknown record count cut off inside its first record is an error, not an empty file', () => {
    const whole = buildEdf({ startDate: '10.01.24', startTime: '23.00.30', recordSeconds: 60, declaredRecords: -1, signals: [press, leak()],
      records: [[Array(30).fill(500), [...fifteen(10), ...fifteen(10)]]] })
    // The 768-byte header (256 + 2 signals x 256), then 30 of the record's 120 bytes.
    expect(() => readLeakTrace(whole.slice(0, 768 + 30))).toThrow('Leak.2s is cut off before its first record')
  })
})

describe('reading a card', () => {
  const minutes = { physMin: 0, physMax: 1440, digMin: 0, digMax: 1440, samplesPerRecord: 20 }
  const one = (label: string, physMin: number, physMax: number, digMin: number, digMax: number, unit = '') =>
    ({ label, physMin, physMax, digMin, digMax, samplesPerRecord: 1, unit })
  const slots = (...values: number[]) => [...values, ...Array(20 - values.length).fill(-1)]
  // Signals in an order unlike the real file's, and one the reader ignores, so it must look them up by label.
  const STR = buildEdf({
    startDate: '10.01.24', startTime: '12.00.00', recordSeconds: 86400,
    signals: [
      one('Leak.95', 0, 2, 0, 100, 'L/s'), { label: 'MaskOn', ...minutes }, { label: 'MaskOff', ...minutes },
      one('AHI', 0, 240, 0, 2400), one('RespRate.50', 0, 90, 0, 450), one('MaskPress.50', 0, 40, 0, 2000),
    ],
    records: [
      // 2024-01-10: a 2-minute mask check at 22:00, then 23:00-06:00 and 06:20-07:20.
      [[12], slots(600, 660, 1100), slots(602, 1080, 1160), [52], [80], [512]],
      // 2024-01-11: no therapy.
      [[0], slots(), slots(), [0], [0], [0]],
      // 2024-01-12: only a 3-minute mask check.
      [[0], slots(700), slots(703), [0], [0], [0]],
    ],
  })
  const eventFile = (startDate: string, startTime: string, ...records: Uint8Array[]) => buildEdf({
    startDate, startTime, reserved: 'EDF+D', recordSeconds: 0, signals: [ANNOTATIONS],
    records: records.map((r) => [concat(tal('+0', null), r)]),
  })
  const dir = 'AirSense11/DATALOG/'
  const unreadable = `${dir}20240110/20240110_230031_EVE.edf`
  const events = [
    { path: `${dir}20240110/20240110_230030_EVE.edf`, bytes: eventFile('10.01.24', '23.00.30',
      tal('+0', '0', 'Recording starts'),
      tal('+600', '20', 'Obstructive Apnea'), // ends 23:10:30
      tal('+7200', '15', 'Hypopnea'), // ends 01:00:30
      tal('+25800', '10', 'Central Apnea'), // ends 06:10:30, between the two sessions: dropped
    ) },
    { path: `${dir}20240110/20240110_230030_CSL.edf`, bytes: eventFile('10.01.24', '23.00.30',
      tal('+1000', null, 'CSR Start'), tal('+1300', '0', 'CSR End')) },
    // After midnight but before noon, so still the night of 2024-01-10.
    { path: `${dir}20240110/20240111_062005_EVE.edf`, bytes: eventFile('11.01.24', '06.20.05', tal('+625', '12', 'Arousal')) },
    // Inside the mask check: dropped.
    { path: `${dir}20240110/20240110_220010_EVE.edf`, bytes: eventFile('10.01.24', '22.00.10', tal('+60', '10', 'Obstructive Apnea')) },
    // A night with no therapy in STR.edf: dropped.
    { path: `${dir}20240111/20240111_230000_EVE.edf`, bytes: eventFile('11.01.24', '23.00.00', tal('+60', '10', 'Hypopnea')) },
    { path: unreadable, bytes: new Uint8Array(10) },
  ]
  const night = { night: '2024-01-10', clock: 'America/Toronto' }
  const nightly = { source_device: 'AirSense 11', started_at: '2024-01-11T04:00:00.000Z', ended_at: '2024-01-11T12:20:00.000Z', metadata: night }
  const event = (type: string, label: string, seconds: number, start: string, end: string) => ({
    metric_type: `cpap.event.${type}`, value: seconds, unit: 's', source_device: 'AirSense 11',
    started_at: start, ended_at: end, metadata: { ...night, label },
  })

  test('nightly values from STR.edf and events from EVE and CSL, as Samples with true timestamps', () => {
    const card = readCard({ str: STR, events }, { timeZone: 'America/Toronto' })
    expect(card.samples).toEqual([
      { metric_type: 'cpap.ahi', value: 5.2, unit: 'events/h', ...nightly },
      { metric_type: 'cpap.leak_p95', value: 14.4, unit: 'L/min', ...nightly },
      { metric_type: 'cpap.pressure_median', value: 10.24, unit: 'cmH2O', ...nightly },
      { metric_type: 'cpap.usage_hours', value: 8, unit: 'h', ...nightly },
      event('obstructive_apnea', 'Obstructive Apnea', 20, '2024-01-11T04:10:10.000Z', '2024-01-11T04:10:30.000Z'),
      event('csr', 'CSR', 300, '2024-01-11T04:17:10.000Z', '2024-01-11T04:22:10.000Z'),
      event('hypopnea', 'Hypopnea', 15, '2024-01-11T06:00:15.000Z', '2024-01-11T06:00:30.000Z'),
      event('arousal', 'Arousal', 12, '2024-01-11T11:30:18.000Z', '2024-01-11T11:30:30.000Z'),
    ])
    expect(card.nights).toEqual([{ date: '2024-01-10', sessions: 2, usageHours: 8, events: 4 }])
    expect(card.stats).toEqual({ nights: 1, sessions: 2, stubSessions: 2, events: 4, droppedEvents: 3, leakMinutes: 0, droppedLeakFiles: 0,
      unreadable: [{ path: unreadable, reason: 'Not an EDF file: the header is cut short' }], skippedSummaries: [] })
  })

  test('with the machine clock as a fixed offset, a summer Night is not moved by daylight time', () => {
    // 2024-07-10: 23:00-06:00 by a clock kept at UTC-5. Noon is 17:00Z; 660 and 1080 minutes later
    // are 04:00Z and 11:00Z on 07-11. Toronto (EDT, UTC-4) would have put them an hour earlier.
    const card = readCard({ str: strFor('10.07.24', [660], [1080]), events: [
      { path: `${dir}20240710/20240710_230030_EVE.edf`, bytes: eventFile('10.07.24', '23.00.30', tal('+600', '20', 'Hypopnea')) },
    ] }, { timeZone: '-05:00' })
    const ahi = card.samples.find((x) => x.metric_type === 'cpap.ahi')!
    expect([ahi.started_at, ahi.ended_at]).toEqual(['2024-07-11T04:00:00.000Z', '2024-07-11T11:00:00.000Z'])
    expect(ahi.metadata).toEqual({ night: '2024-07-10', clock: '-05:00' })
    const hypopnea = card.samples.find((x) => x.metric_type === 'cpap.event.hypopnea')!
    expect([hypopnea.started_at, hypopnea.ended_at]).toEqual(['2024-07-11T04:10:10.000Z', '2024-07-11T04:10:30.000Z'])
    expect(card.nights.map((n) => n.date)).toEqual(['2024-07-10'])
  })

  test('reading the same card twice gives the same Samples', () => {
    const a = readCard({ str: STR, events }, { timeZone: 'America/Toronto' })
    const b = readCard({ str: STR, events: [...events].reverse() }, { timeZone: 'America/Toronto' })
    expect(b.samples).toEqual(a.samples)
  })

  test('a CSR start with no end is dropped', () => {
    const card = readCard({ str: STR, events: [
      { path: `${dir}20240110/20240110_230030_CSL.edf`, bytes: eventFile('10.01.24', '23.00.30', tal('+1000', null, 'CSR Start')) },
    ] }, { timeZone: 'UTC' })
    expect(card.stats.events).toBe(0)
    expect(card.stats.droppedEvents).toBe(1)
  })

  // One STR record from noon on `date` (dd.mm.yy), with the given session slots and signal overrides.
  const strFor = (date: string, ons: number[], offs: number[], over: { ahi?: ReturnType<typeof one>; leakUnit?: string } = {}) => buildEdf({
    startDate: date, startTime: '12.00.00', recordSeconds: 86400,
    signals: [{ label: 'MaskOn', ...minutes }, { label: 'MaskOff', ...minutes }, over.ahi ?? one('AHI', 0, 240, 0, 2400),
      one('Leak.95', 0, 2, 0, 100, over.leakUnit ?? 'L/s'), one('MaskPress.50', 0, 40, 0, 2000)],
    records: [[slots(...ons), slots(...offs), [52], [12], [512]]],
  })

  test('across a clock change, times measured from noon or a file start are elapsed time, not wall time', () => {
    // Toronto falls back at 02:00 EDT on 2024-11-03. Noon EDT on 11-02 is 16:00Z; 600 and 1200
    // minutes later are 02:00Z and 12:00Z on 11-03, ten hours apart.
    const card = readCard({ str: strFor('02.11.24', [600], [1200]), events: [
      // Starts 22:00:30 EDT (02:00:30Z); an event ending 18000 s (5 h) later ends at 07:00:30Z.
      { path: `${dir}20241102/20241102_220030_EVE.edf`, bytes: eventFile('02.11.24', '22.00.30', tal('+18000', '20', 'Hypopnea')) },
    ] }, { timeZone: 'America/Toronto' })
    const ahi = card.samples.find((x) => x.metric_type === 'cpap.ahi')!
    expect([ahi.started_at, ahi.ended_at]).toEqual(['2024-11-03T02:00:00.000Z', '2024-11-03T12:00:00.000Z'])
    expect(card.samples.find((x) => x.metric_type === 'cpap.usage_hours')!.value).toBe(10)
    const hypopnea = card.samples.find((x) => x.metric_type === 'cpap.event.hypopnea')!
    expect([hypopnea.started_at, hypopnea.ended_at]).toEqual(['2024-11-03T07:00:10.000Z', '2024-11-03T07:00:30.000Z'])
  })

  test('a file started in the hour a clock repeats is placed in the session it belongs to', () => {
    // Toronto falls back at 02:00 EDT on 2024-11-03, so 01:00-02:00 happens twice. Noon EDT on 11-02
    // is 16:00Z. Sessions 600-780 (22:00-01:00 EDT, 02:00Z-05:00Z) and 870-1200 (06:30Z-12:00Z,
    // which is 01:30-07:00 EST, the second 01:30).
    const card = readCard({ str: strFor('02.11.24', [600, 870], [780, 1200]), events: [
      // Starts at the second 01:30 (06:30Z); a 10 s hypopnea ending 600 s later spans 06:39:50Z-06:40:00Z.
      { path: `${dir}20241102/20241103_013000_EVE.edf`, bytes: eventFile('03.11.24', '01.30.00', tal('+600', '10', 'Hypopnea')) },
    ] }, { timeZone: 'America/Toronto' })
    const hypopnea = card.samples.find((x) => x.metric_type === 'cpap.event.hypopnea')
    expect([hypopnea?.started_at, hypopnea?.ended_at]).toEqual(['2024-11-03T06:39:50.000Z', '2024-11-03T06:40:00.000Z'])
    expect(card.stats.droppedEvents).toBe(0)
  })

  test('a file started in the minute before noon belongs to the Night whose session it starts', () => {
    // UTC. STR's record from noon on 2024-01-10 has a session from minute 0 (12:00, mask-on rounded
    // to the minute) to 420. The EVE file starts at 11:59:40, before that noon; its hypopnea ends
    // 600 s later, at 12:09:40.
    const card = readCard({ str: strFor('10.01.24', [0], [420]), events: [
      { path: `${dir}20240110/20240110_115940_EVE.edf`, bytes: eventFile('10.01.24', '11.59.40', tal('+600', '10', 'Hypopnea')) },
    ] }, { timeZone: 'UTC' })
    const hypopnea = card.samples.find((x) => x.metric_type === 'cpap.event.hypopnea')
    expect([hypopnea?.started_at, hypopnea?.metadata]).toEqual(['2024-01-10T12:09:30.000Z', { night: '2024-01-10', label: 'Hypopnea', clock: 'UTC' }])
    expect(card.stats.droppedEvents).toBe(0)
  })

  test('an event whose label would make a metric type over 256 characters is left out, not uploaded', () => {
    // Ingest refuses a whole batch with a metric_type over 256 characters, so one such event must not reach it.
    const wide = { ...ANNOTATIONS, samplesPerRecord: 250 }
    const bytes = buildEdf({ startDate: '10.01.24', startTime: '23.00.00', reserved: 'EDF+D', recordSeconds: 0, signals: [wide],
      records: [[concat(tal('+0', null), tal('+600', '10', 'Hypopnea'), tal('+700', '10', 'X'.repeat(300)))]] })
    const card = readCard({ str: strFor('10.01.24', [660], [1080]), events: [{ path: `${dir}20240110/20240110_230000_EVE.edf`, bytes }] }, { timeZone: 'UTC' })
    expect(card.samples.filter((x) => x.metric_type.startsWith('cpap.event.')).map((x) => x.metric_type)).toEqual(['cpap.event.hypopnea'])
    expect(card.stats.droppedEvents).toBe(1)
  })

  test('a mask slot with no scale is no session, and the card still reads', () => {
    // MaskOn with digital min = max = 5: a slot holding 5 scales as 0/0, not a number.
    const noScale = buildEdf({
      startDate: '10.01.24', startTime: '12.00.00', recordSeconds: 86400,
      signals: [{ label: 'MaskOn', physMin: 0, physMax: 1440, digMin: 5, digMax: 5, samplesPerRecord: 20 }, { label: 'MaskOff', ...minutes },
        one('AHI', 0, 240, 0, 2400), one('Leak.95', 0, 2, 0, 100, 'L/s'), one('MaskPress.50', 0, 40, 0, 2000)],
      records: [[slots(5), slots(1080), [52], [12], [512]]],
    })
    const card = readCard({ str: noScale, events: [] }, { timeZone: 'UTC' })
    expect(card.nights).toEqual([])
    expect(card.samples).toEqual([])
  })

  test('the Night spans its first mask-on to its last mask-off whatever the slot order', () => {
    const card = readCard({ str: strFor('10.01.24', [1100, 660], [1160, 1080]), events: [] }, { timeZone: 'UTC' })
    const ahi = card.samples.find((x) => x.metric_type === 'cpap.ahi')!
    // Noon UTC plus 660 and 1160 minutes.
    expect([ahi.started_at, ahi.ended_at]).toEqual(['2024-01-10T23:00:00.000Z', '2024-01-11T07:20:00.000Z'])
  })

  test('a signal with no scale (digital min = max) is left out, not uploaded as null', () => {
    const card = readCard({ str: strFor('10.01.24', [660], [1080], { ahi: one('AHI', 0, 240, 7, 7) }), events: [] }, { timeZone: 'UTC' })
    expect(card.samples.map((x) => x.metric_type).sort()).toEqual(['cpap.leak_p95', 'cpap.pressure_median', 'cpap.usage_hours'])
  })

  test('leak in L/min is kept as is; leak in an unknown unit is skipped and said so', () => {
    const perMinute = readCard({ str: strFor('10.01.24', [660], [1080], { leakUnit: 'L/min' }), events: [] }, { timeZone: 'UTC' })
    expect(perMinute.samples.find((x) => x.metric_type === 'cpap.leak_p95')!.value).toBe(0.24) // 12 of 100 steps of 0..2
    const unknown = readCard({ str: strFor('10.01.24', [660], [1080], { leakUnit: 'cfm' }), events: [] }, { timeZone: 'UTC' })
    expect(unknown.samples.some((x) => x.metric_type === 'cpap.leak_p95')).toBe(false)
    // STR.edf was read; only one of its summaries is left out, so it is no unreadable file.
    expect(unknown.stats.unreadable).toEqual([])
    expect(unknown.stats.skippedSummaries).toEqual(['Leak.95 is in an unknown unit (cfm); leak skipped'])
  })

  test('an STR.edf without Leak.95 or MaskPress.50 still reads, without that metric, and says so', () => {
    const str = buildEdf({ startDate: '10.01.24', startTime: '12.00.00', recordSeconds: 86400,
      signals: [{ label: 'MaskOn', ...minutes }, { label: 'MaskOff', ...minutes }, one('AHI', 0, 240, 0, 2400)],
      records: [[slots(660), slots(1080), [52]]] })
    const card = readCard({ str, events: [] }, { timeZone: 'UTC' })
    expect(card.samples.map((x) => x.metric_type).sort()).toEqual(['cpap.ahi', 'cpap.usage_hours'])
    expect(card.stats.unreadable).toEqual([])
    expect(card.stats.skippedSummaries).toEqual(['STR.edf has no Leak.95 signal; leak skipped', 'STR.edf has no MaskPress.50 signal; pressure skipped'])
  })

  test('an STR.edf without a needed signal, or not one record a day, is refused by name', () => {
    const without = buildEdf({ startDate: '10.01.24', startTime: '12.00.00', recordSeconds: 86400,
      signals: [{ label: 'MaskOn', ...minutes }, { label: 'MaskOff', ...minutes }], records: [] })
    expect(() => readCard({ str: without, events: [] }, { timeZone: 'UTC' })).toThrow(/AHI/)
    const hourly = buildEdf({ startDate: '10.01.24', startTime: '12.00.00', recordSeconds: 3600,
      signals: [{ label: 'MaskOn', ...minutes }], records: [] })
    expect(() => readCard({ str: hourly, events: [] }, { timeZone: 'UTC' })).toThrow(/one record a day/)
  })
})

describe('reading a card\'s leak traces', () => {
  const minutes = { physMin: 0, physMax: 1440, digMin: 0, digMax: 1440, samplesPerRecord: 20 }
  const one = (label: string, physMin: number, physMax: number, digMin: number, digMax: number, unit = '') =>
    ({ label, physMin, physMax, digMin, digMax, samplesPerRecord: 1, unit })
  const slots = (...values: number[]) => [...values, ...Array(20 - values.length).fill(-1)]
  const strFor = (ons: number[], offs: number[]) => buildEdf({
    startDate: '10.01.24', startTime: '12.00.00', recordSeconds: 86400,
    signals: [{ label: 'MaskOn', ...minutes }, { label: 'MaskOff', ...minutes }, one('AHI', 0, 240, 0, 2400),
      one('Leak.95', 0, 2, 0, 100, 'L/s'), one('MaskPress.50', 0, 40, 0, 2000)],
    records: [[slots(...ons), slots(...offs), [52], [12], [512]]],
  })
  const wall = (h: number, m: number, s: number, day = 10) => Date.UTC(2024, 0, day, h, m, s)
  const dir = 'AirSense11/DATALOG/20240110/'
  const leaks = (card: ReturnType<typeof readCard>) => card.samples.filter((x) => x.metric_type === 'cpap.leak_trace')

  test('a session\'s trace is stored an hour of clock minutes at a time, from its first reading', () => {
    // Toronto, EST (UTC-5). Sessions 23:00-06:00 and 06:20-07:20, plus a 2-minute mask check at 22:00.
    const str = strFor([600, 660, 1100], [602, 1080, 1160])
    // 130 minutes from 23:00 (the file starts 23:00:30): an unknown first minute, 59 at 10, then 30 at
    // 20 and 30 at 30, then 10 unknown minutes.
    const lpm = [null, ...Array(59).fill(10), ...Array(30).fill(20), ...Array(30).fill(30), ...Array(10).fill(null)]
    const card = readCard({ str, events: [], leaks: [
      { path: `${dir}20240110_230030_PLD.edf`, trace: { startWall: wall(23, 0, 30), first: 0, end: 129 * 60_000, minute0: -30_000, lpm } },
      { path: `${dir}20240110_220010_PLD.edf`, trace: { startWall: wall(22, 0, 10), first: 0, end: 60_000, minute0: -10_000, lpm: [9] } },
      { path: `${dir}20240111_062005_PLD.edf`, trace: { startWall: wall(6, 20, 5, 11), first: 0, end: 2_000, minute0: -5_000, lpm: [7.5] } },
      { path: `${dir}20240110_230031_PLD.edf`, error: 'No leak signal (the file has MaskPress.2s)' },
      { path: `${dir}20240110_225959_PLD.edf`, trace: null },
    ] }, { timeZone: 'America/Toronto' })
    const sample = (value: number, start: string, end: string, minute0: string, values: (number | null)[]) => ({
      metric_type: 'cpap.leak_trace', value, unit: 'L/min', source_device: 'AirSense 11', started_at: start, ended_at: end,
      metadata: { night: '2024-01-10', minute0, lpm: values, clock: 'America/Toronto' },
    })
    expect(leaks(card)).toEqual([
      sample(10, '2024-01-11T04:00:30.000Z', '2024-01-11T05:00:00.000Z', '2024-01-11T04:00:00.000Z', lpm.slice(0, 60)),
      sample(25, '2024-01-11T05:00:00.000Z', '2024-01-11T06:00:00.000Z', '2024-01-11T05:00:00.000Z', lpm.slice(60, 120)),
      // 10 unknown minutes make no Sample; the mask check's trace is left out.
      sample(7.5, '2024-01-11T11:20:05.000Z', '2024-01-11T11:20:07.000Z', '2024-01-11T11:20:00.000Z', [7.5]),
    ])
    expect(card.stats.leakMinutes).toBe(59 + 60 + 1)
    // The mask check's trace, and the file with no records.
    expect(card.stats.droppedLeakFiles).toBe(2)
    expect(card.stats.unreadable).toEqual([{ path: `${dir}20240110_230031_PLD.edf`, reason: 'No leak signal (the file has MaskPress.2s)' }])
  })

  test('a trace that runs on after mask-off is cut a minute after it', () => {
    // UTC. One session 23:00-06:00 (STR minutes 660-1080 from noon). The file starts 23:00:30 and
    // holds 425 minutes at 10 L/min, to 06:05; mask-off plus a minute is 06:01:00.
    const card = readCard({ str: strFor([660], [1080]), events: [], leaks: [
      { path: `${dir}20240110_230030_PLD.edf`, trace: { startWall: wall(23, 0, 30), first: 0, end: 424 * 60_000 + 30_000, minute0: -30_000, lpm: Array(425).fill(10) } },
    ] }, { timeZone: 'UTC' })
    const traces = leaks(card)
    // Minutes 23:00 to 06:00 are kept: 421 of them, in seven full hours and one minute.
    expect(card.stats.leakMinutes).toBe(421)
    expect(traces.length).toBe(8)
    expect(traces.at(-1)).toMatchObject({ started_at: '2024-01-11T06:00:00.000Z', ended_at: '2024-01-11T06:01:00.000Z', metadata: { lpm: [10] } })
  })

  test('a trace whose first reading is a minute after mask-off is left out, not stored with no length', () => {
    // UTC. One session 23:00-06:00; the file's first reading is at 06:01:00, mask-off plus a minute.
    const card = readCard({ str: strFor([660], [1080]), events: [], leaks: [
      { path: `${dir}20240111_060100_PLD.edf`, trace: { startWall: wall(6, 1, 0, 11), first: 0, end: 5 * 60_000, minute0: 0, lpm: Array(5).fill(80) } },
    ] }, { timeZone: 'UTC' })
    expect(leaks(card)).toEqual([])
    expect(card.stats.droppedLeakFiles).toBe(1)
  })

  test('a file starting on the next session\'s mask-on belongs to that session, not the one just ended', () => {
    // UTC. Sessions 22:00-22:30 and 22:31-23:30 (STR minutes 600-630 and 631-690 from noon). Both
    // files hold 59 minutes at 10 L/min; one starts at 22:31:00 exactly, the other at 22:30:50, which
    // STR rounds to session 2's 22:31.
    for (const [seconds, file] of [[0, '20240110_223100_PLD.edf'], [50, '20240110_223050_PLD.edf']] as const) {
      const start = seconds ? wall(22, 30, seconds) : wall(22, 31, 0)
      const card = readCard({ str: strFor([600, 631], [630, 690]), events: [], leaks: [
        { path: `${dir}${file}`, trace: { startWall: start, first: 0, end: 59 * 60_000, minute0: -seconds * 1000, lpm: Array(59).fill(10) } },
      ] }, { timeZone: 'UTC' })
      expect(card.stats.leakMinutes).toBe(59)
      expect(card.stats.droppedLeakFiles).toBe(0)
      expect(leaks(card).map((x) => x.started_at)).toEqual([new Date(start).toISOString()])
    }
  })

  test('sessions that share a clock minute never share a started_at', () => {
    // UTC. 22:05-23:05 and 23:06-00:00; the first file ends 23:05:20, the second starts 23:05:50.
    const card = readCard({ str: strFor([605, 666], [665, 720]), events: [], leaks: [
      { path: `${dir}20240110_220520_PLD.edf`, trace: { startWall: wall(22, 5, 20), first: 0, end: 3_600_000, minute0: -20_000, lpm: Array(61).fill(5) } },
      { path: `${dir}20240110_230550_PLD.edf`, trace: { startWall: wall(23, 5, 50), first: 0, end: 600_000, minute0: -50_000, lpm: Array(11).fill(6) } },
    ] }, { timeZone: 'UTC' })
    expect(leaks(card).map((x) => [x.started_at, (x.metadata as { minute0: string }).minute0])).toEqual([
      ['2024-01-10T22:05:20.000Z', '2024-01-10T22:05:00.000Z'],
      ['2024-01-10T23:05:00.000Z', '2024-01-10T23:05:00.000Z'],
      ['2024-01-10T23:05:50.000Z', '2024-01-10T23:05:00.000Z'],
    ])
  })
})

describe('uploading', () => {
  const samples = (n: number) => Array.from({ length: n }, (_, i) => ({ metric_type: 'cpap.ahi', value: i, unit: 'events/h',
    source_device: 'AirSense 11', started_at: new Date(Date.UTC(2025, 0, 1) + i * 86_400_000).toISOString(), ended_at: null, metadata: null }))
  const reply = (status: number, body: object) => new Response(JSON.stringify(body), { status })

  test('sends batches of at most 1000, one at a time, and reports progress', async () => {
    const sizes: number[] = []
    const progress: number[] = []
    let inFlight = 0
    const out = await uploadSamples(samples(2300), {
      post: async (batch) => {
        expect(++inFlight).toBe(1)
        await new Promise((r) => setTimeout(r, 1))
        sizes.push(batch.length)
        inFlight--
        return reply(200, { inserted: batch.length, replaced: 0 })
      },
      wait: async () => { throw new Error('no wait expected') },
      onProgress: (sent) => progress.push(sent),
    })
    expect(sizes).toEqual([1000, 1000, 300])
    expect(progress).toEqual([1000, 2000, 2300])
    expect(out).toEqual({ inserted: 2300, batches: 3 })
  })

  test('a 429 waits a minute and resends the same batch; three in a row give up', async () => {
    const waits: number[] = []
    const statuses = [429, 200]
    const sent: number[] = []
    const replies: Response[] = []
    await uploadSamples(samples(5), {
      post: async (batch) => { sent.push(batch.length); replies.push(reply(statuses.shift()!, { inserted: batch.length })); return replies.at(-1)! },
      wait: async (ms) => { waits.push(ms) },
    })
    expect(waits).toEqual([60_000])
    expect(sent).toEqual([5, 5])
    // The 429's body is read before the wait, so its connection is not held for the minute.
    expect(replies.every((r) => r.bodyUsed)).toBe(true)

    await expect(uploadSamples(samples(5), {
      post: async () => reply(429, { error: 'slow down' }),
      wait: async () => {},
    })).rejects.toThrow(/Too many requests/)
  })

  test('any other failure stops the upload with the server\'s message', async () => {
    let calls = 0
    await expect(uploadSamples(samples(1500), {
      post: async () => (++calls === 1 ? reply(200, { inserted: 1000 }) : reply(400, { error: 'value must be a finite number or null' })),
      wait: async () => {},
    })).rejects.toThrow('value must be a finite number or null')
    expect(calls).toBe(2)
  })
})
