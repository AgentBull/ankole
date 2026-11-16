import { beforeAll, expect, test } from 'bun:test'
import i18n, { loadLocale } from '../../common/i18n'
import { TAB_COLORS } from './spreadsheet-sheet-tabs'
import { FILL_COLORS, TEXT_COLORS } from './spreadsheet-toolbar'

const LOCALES = ['en-US', 'zh-Hans-CN', 'ja-JP', 'ko-KR']

beforeAll(() => Promise.all(LOCALES.map(locale => loadLocale(locale))))

test('every swatch of each colour palette has a distinct name in each locale', () => {
  for (const locale of LOCALES) {
    for (const palette of [TEXT_COLORS, FILL_COLORS, TAB_COLORS]) {
      const names = palette.map(token =>
        i18n.getResource(locale, 'translation', `pod.spreadsheet.colors.${token.replace('--color-', '')}`)
      )
      expect({ locale, missing: palette.filter((_, index) => typeof names[index] !== 'string') }).toEqual({
        locale,
        missing: []
      })
      expect(new Set(names).size).toBe(names.length)
    }
  }
})
