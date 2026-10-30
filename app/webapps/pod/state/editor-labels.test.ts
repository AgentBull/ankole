import { expect, test } from 'bun:test'
import { editorPhrases } from '@ankole/block-editor/editor'
import i18n, { loadLocale } from '../../common/i18n'
import { editorLabels } from './editor-labels'

for (const locale of ['en-US', 'zh-Hans-CN', 'ja-JP', 'ko-KR'] as const) {
  test(`the ${locale} Pod catalog supplies every editor interface label`, async () => {
    await loadLocale(locale)
    const labels = editorLabels(locale)
    for (const key of Object.keys(editorPhrases.phrases) as (keyof typeof labels)[]) {
      expect(i18n.getResource(locale, 'translation', `pod.editor.${key}`)).toBe(labels[key])
      expect(labels[key]).not.toBe(`pod.editor.${key}`)
    }
  })
}
