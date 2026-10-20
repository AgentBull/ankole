import { t } from 'i18next'
import { editorPhrases, type EditorLabels } from '@ankole/block-editor/editor'

export function editorLabels(locale: string): EditorLabels {
  return Object.fromEntries(
    Object.keys(editorPhrases.phrases).map(key => [key, t(`pod.editor.${key}`, { lng: locale })])
  ) as EditorLabels
}
