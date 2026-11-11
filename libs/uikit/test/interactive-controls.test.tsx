import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  addMonthsPlain,
  applyDateRangeSelection,
  buildCalendarGrid,
  clampAndRoundNumber,
  constrainDateRange,
  DatePicker,
  DateRangePicker,
  FileDropzone,
  formatEditableNumber,
  formatISODate,
  formatSliderDisplay,
  matchesAcceptSpec,
  NumberInput,
  parseEditableNumber,
  parseISODate,
  partitionDroppedFiles,
  PrincipalBadge,
  principalInitials,
  Slider,
  stepEditableNumber
} from '../src'

describe('Slider', () => {
  test('renders single and dual-thumb range sliders with accessible range inputs and formatted value readout', () => {
    const singleHtml = renderToStaticMarkup(
      <Slider label="Discount rate" value={15} min={0} max={50} showValue formatValue={v => `${v}%`} />
    )
    expect(singleHtml).toContain('data-slot="slider"')
    expect(singleHtml).toContain('Discount rate')
    expect(singleHtml).toContain('15%')
    expect(singleHtml).toContain('type="range"')

    const rangeHtml = renderToStaticMarkup(
      <Slider aria-label="Target margin band" value={[25, 45]} min={0} max={80} showValue formatValue={v => `${v}%`} />
    )
    expect(rangeHtml).toContain('25% – 45%')
    expect((rangeHtml.match(/type="range"/g) ?? []).length).toBe(2)
    expect(formatSliderDisplay([10, 30], v => `$${v}`)).toBe('$10 – $30')
  })
})

describe('NumberInput', () => {
  test('clamps, rounds, parses intermediate edits, and steps without floating-point drift', () => {
    expect(clampAndRoundNumber(12.3456, { min: 0, max: 100, precision: 2 })).toBe(12.35)
    expect(clampAndRoundNumber(-1.005, { precision: 2 })).toBe(-1.01)
    expect(clampAndRoundNumber(-5, { min: 0, max: 100 })).toBe(0)
    expect(clampAndRoundNumber(-0, { precision: 2 })).toBe(0)

    expect(parseEditableNumber('')).toEqual({ state: 'empty' })
    expect(parseEditableNumber('-')).toEqual({ state: 'intermediate' })
    expect(parseEditableNumber('.')).toEqual({ state: 'intermediate' })
    expect(parseEditableNumber('-', { allowNegative: false })).toEqual({ state: 'invalid' })
    expect(parseEditableNumber('1,250.5')).toEqual({ state: 'valid', value: 1250.5 })
    expect(parseEditableNumber('12abc')).toEqual({ state: 'invalid' })

    expect(stepEditableNumber(0.1, 1, { step: 0.2 })).toBe(0.3)
    expect(stepEditableNumber(0, 1, { step: 1e-7 })).toBe(1e-7)
    expect(stepEditableNumber(10, 1, { step: 5, max: 12 })).toBe(12)
    expect(formatEditableNumber(1250.5, { precision: 2, locale: 'en-US', formatOptions: { useGrouping: true } })).toBe(
      '1,250.50'
    )
    expect(
      formatEditableNumber(1250.5, {
        precision: 2,
        locale: 'en-US',
        formatOptions: { useGrouping: true },
        focused: true
      })
    ).toBe('1250.5')
  })

  test('renders decimal inputmode, prefix/suffix, and non-submitting stepper buttons', () => {
    const html = renderToStaticMarkup(
      <NumberInput aria-label="Unit price" value={49.9} precision={2} min={0} prefix="$" suffix="USD" showStepper />
    )
    expect(html).toContain('data-slot="number-input"')
    expect(html).toContain('inputMode="decimal"')
    expect(html).toContain('value="49.90"')
    expect(html).toContain('>$</span>')
    expect(html).toContain('>USD</span>')
    expect((html.match(/type="button"/g) ?? []).length).toBe(2)
  })
})

describe('DatePicker and DateRangePicker', () => {
  test('handles location-agnostic ISO calendar dates without timezone drift across leap years', () => {
    expect(parseISODate('2028-02-29')).toEqual({ year: 2028, month: 2, day: 29 })
    expect(parseISODate('2027-02-29')).toBeNull()
    expect(parseISODate('2026-13-01')).toBeNull()
    expect(formatISODate({ year: 2026, month: 4, day: 5 })).toBe('2026-04-05')
    expect(addMonthsPlain({ year: 2026, month: 1 }, -1)).toEqual({ year: 2025, month: 12 })
    expect(addMonthsPlain({ year: 2026, month: 12 }, 1)).toEqual({ year: 2027, month: 1 })

    const febGrid = buildCalendarGrid(2026, 2)
    const nonNullDays = febGrid.flat().filter(Boolean)
    expect(nonNullDays.length).toBe(28)
    expect(formatISODate(nonNullDays[0]!)).toBe('2026-02-01')
    expect(formatISODate(nonNullDays.at(-1)!)).toBe('2026-02-28')

    const firstPick = applyDateRangeSelection({ from: null, to: null }, '2026-11-10')
    expect(firstPick).toEqual({ from: '2026-11-10', to: null })
    const reversedSecondPick = applyDateRangeSelection(firstPick, '2026-11-03')
    expect(reversedSecondPick).toEqual({ from: '2026-11-03', to: '2026-11-10' })
    const restartPick = applyDateRangeSelection(reversedSecondPick, '2026-11-15')
    expect(restartPick).toEqual({ from: '2026-11-15', to: null })

    expect(constrainDateRange({ from: '2026-10-20', to: '2026-11-10' }, '2026-11-01', '2026-11-15')).toEqual({
      from: '2026-11-01',
      to: '2026-11-10'
    })
    expect(constrainDateRange({ from: '2026-10-20', to: null }, '2026-11-01', '2026-11-15')).toEqual({
      from: '2026-11-01',
      to: null
    })
    expect(constrainDateRange({ from: '2026-11-20', to: null }, '2026-11-01', '2026-11-15')).toBeNull()
    expect(constrainDateRange({ from: '2026-10-01', to: '2026-10-31' }, '2026-11-01', '2026-11-15')).toBeNull()
    expect(constrainDateRange({ from: '2026-11-20', to: '2026-11-25' }, '2026-11-01', '2026-11-15')).toBeNull()
  })

  test('renders ISO summary, store timezone badge, and non-submitting clear trigger', () => {
    const pickerHtml = renderToStaticMarkup(
      <DatePicker aria-label="Target delivery date" value="2026-11-20" timezone="America/Los_Angeles" />
    )
    expect(pickerHtml).toContain('2026-11-20')
    expect(pickerHtml).toContain('America/Los_Angeles')
    expect(pickerHtml).toContain('aria-label="Clear date"')

    const rangeHtml = renderToStaticMarkup(
      <DateRangePicker aria-label="Settlement window" value={{ from: '2026-11-01', to: '2026-11-11' }} timezone="UTC" />
    )
    expect(rangeHtml).toContain('2026-11-01 – 2026-11-11')
    expect(rangeHtml).toContain('aria-label="Clear date range"')
  })
})

describe('FileDropzone and PrincipalBadge', () => {
  test('validates file extensions, MIME wildcards, byte limits, and file count caps', () => {
    expect(matchesAcceptSpec({ name: 'statement.csv', type: 'text/csv' }, '.csv,image/*')).toBe(true)
    expect(matchesAcceptSpec({ name: 'damage.webp', type: 'image/webp' }, '.csv,image/*')).toBe(true)
    expect(matchesAcceptSpec({ name: 'archive.zip', type: 'application/zip' }, '.csv,image/*')).toBe(false)

    const result = partitionDroppedFiles(
      [
        { name: 'ok-1.csv', size: 512, type: 'text/csv' },
        { name: 'bad.exe', size: 100, type: 'application/octet-stream' },
        { name: 'huge.csv', size: 10_000, type: 'text/csv' },
        { name: 'ok-2.csv', size: 512, type: 'text/csv' },
        { name: 'overflow.csv', size: 512, type: 'text/csv' }
      ],
      { accept: '.csv', maxSizeBytes: 2048, maxFiles: 2 }
    )
    expect(result.accepted.map(f => f.name)).toEqual(['ok-1.csv', 'ok-2.csv'])
    expect(result.rejected.map(r => [r.file.name, r.reason])).toEqual([
      ['bad.exe', 'invalid_type'],
      ['huge.csv', 'file_too_large'],
      ['overflow.csv', 'too_many_files']
    ])

    const singleDrop = partitionDroppedFiles(
      [
        { name: 'first.csv', size: 256, type: 'text/csv' },
        { name: 'second.csv', size: 256, type: 'text/csv' }
      ],
      { multiple: false }
    )
    expect(singleDrop.accepted.map(f => f.name)).toEqual(['first.csv'])
    expect(singleDrop.rejected.map(r => [r.file.name, r.reason])).toEqual([['second.csv', 'too_many_files']])

    const dropzoneHtml = renderToStaticMarkup(
      <FileDropzone label="Upload 3PL statement" description="CSV up to 5 MB" accept=".csv" />
    )
    expect(dropzoneHtml).toContain('Upload 3PL statement')
    expect(dropzoneHtml).toContain('CSV up to 5 MB')
    expect(dropzoneHtml).toContain('type="file"')
    expect(dropzoneHtml).toContain('type="button"')
  })

  test('renders Human and AI Colleague PrincipalBadge states cleanly', () => {
    expect(principalInitials('Maya Lin')).toBe('ML')
    expect(principalInitials('ops-colleague')).toBe('OC')

    const humanHtml = renderToStaticMarkup(<PrincipalBadge uid="maya" name="Maya Lin" kind="human" showUid />)
    expect(humanHtml).toContain('Maya Lin')
    expect(humanHtml).toContain('@maya')
    expect(humanHtml).not.toContain('>AI<')

    const agentHtml = renderToStaticMarkup(
      <PrincipalBadge uid="ops-colleague" name="Ops Colleague" kind="agent" showUid />
    )
    expect(agentHtml).toContain('Ops Colleague')
    expect(agentHtml).toContain('@ops-colleague')
    expect(agentHtml).toContain('>AI<')
  })
})
