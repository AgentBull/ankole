import { describe, expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import {
  CronEditor,
  cronEditorFields,
  cronEditorMode,
  cronEditorModeWithOverride,
  cronExpressionFor
} from '../src/components/cron-editor'

describe('cronEditorMode', () => {
  test('detects every common preset shape', () => {
    expect(cronEditorMode('*/15 * * * *')).toBe('every_minutes')
    expect(cronEditorMode('30 * * * *')).toBe('hourly')
    expect(cronEditorMode('0 5 * * *')).toBe('daily')
    expect(cronEditorMode('0 9 * * 1')).toBe('weekly')
    expect(cronEditorMode('15 8 1 * *')).toBe('monthly')
  })

  test('falls back to custom for shapes the presets cannot represent', () => {
    expect(cronEditorMode('*/15 9-17 * * *')).toBe('custom')
    expect(cronEditorMode('0 5 * 2 *')).toBe('custom')
    expect(cronEditorMode('0 5 1 * 1')).toBe('custom')
    expect(cronEditorMode('not a cron')).toBe('custom')
    expect(cronEditorMode('')).toBe('custom')
  })
})

describe('cronExpressionFor', () => {
  test('round-trips each preset through its parsed fields', () => {
    for (const expression of ['*/15 * * * *', '30 * * * *', '0 5 * * *', '0 9 * * 1', '15 8 1 * *']) {
      const mode = cronEditorMode(expression)
      expect(cronExpressionFor(mode, cronEditorFields(expression))).toBe(expression)
    }
  })

  test('clamps out-of-range fields into the cron domain', () => {
    const fields = cronEditorFields('99 30 40 * *')
    expect(cronExpressionFor('monthly', fields)).toBe('59 23 31 * *')
    expect(cronExpressionFor('every_minutes', { ...fields, interval: 0 })).toBe('*/1 * * * *')
  })

  test('custom mode returns the raw fallback untouched', () => {
    expect(cronExpressionFor('custom', cronEditorFields(''), '*/5 9-17 * * 1-5')).toBe('*/5 9-17 * * 1-5')
  })
})

describe('cronEditorModeWithOverride', () => {
  test('keeps the chosen mode for the expression it was chosen for', () => {
    expect(cronEditorModeWithOverride({ mode: 'custom', forValue: '0 5 * * *' }, '0 5 * * *')).toBe('custom')
  })

  test('an externally replaced value drops the override and re-derives the mode', () => {
    expect(cronEditorModeWithOverride({ mode: 'custom', forValue: '0 5 * * *' }, '0 9 * * 1')).toBe('weekly')
    expect(cronEditorModeWithOverride(undefined, '0 5 * * *')).toBe('daily')
  })
})

describe('CronEditor', () => {
  test('shows the current expression for a detected preset', () => {
    const html = renderToStaticMarkup(<CronEditor value="0 5 * * *" onChange={() => {}} />)
    expect(html).toContain('0 5 * * *')
    expect(html).toContain('Daily')
    expect(html).toContain('type="time"')
  })

  test('keeps an unpresentable expression editable as raw text', () => {
    const html = renderToStaticMarkup(<CronEditor value="*/5 9-17 * * 1-5" onChange={() => {}} />)
    expect(html).toContain('*/5 9-17 * * 1-5')
    expect(html).toContain('Custom expression')
  })
})
