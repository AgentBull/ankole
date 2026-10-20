import { expect, test } from 'bun:test'
import { editorPhrases } from '@ankole/block-editor/editor'
import i18n, { loadLocale } from '../../common/i18n'
import { editorLabels } from './editor-labels'

for (const [locale, title] of [
  ['en-US', 'Text'],
  ['zh-Hans-CN', '正文'],
  ['ja-JP', '本文'],
  ['ko-KR', '본문']
] as const) {
  test(`the ${locale} Pod catalog supplies every editor interface label`, async () => {
    await loadLocale(locale, 'pod')
    const labels = editorLabels(locale)
    expect(labels.paragraph_title).toBe(title)
    for (const key of Object.keys(editorPhrases.phrases) as (keyof typeof labels)[]) {
      expect(i18n.getResource(locale, 'translation', `pod.editor.${key}`)).toBe(labels[key])
      expect(labels[key]).not.toBe(`pod.editor.${key}`)
    }
  })
}
