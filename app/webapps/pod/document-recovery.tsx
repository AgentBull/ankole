import { downloadBlob } from '../common/browser-files'
import { Button } from '@ankole/uikit'
import { parseXml, printMarkdown } from '@ankole/block-editor/document'
import { useSignals } from '@preact/signals-react/runtime'
import { t } from 'i18next'
import type { DocumentDraftModel } from './state/document-draft'
import { documentFilename } from './state/document-tools'

export function DocumentRecovery({ model, title }: { model: InstanceType<typeof DocumentDraftModel>; title: string }) {
  useSignals()
  if (!model.recoveryDrafts.value.length) return null
  return (
    <div role="alert" className="rounded border border-border p-4 text-sm">
      <p>{t('pod.content.another_write_replaced_the_document_so_the_current_content_was')}</p>
      {model.recoveryDrafts.value.map((draft, index) => (
        <div key={draft} className="mt-2 flex gap-2">
          <Button size="sm" variant="outline" onClick={() => downloadDraft(draft, title)}>
            {t('pod.content.export_kept_draft')} {index + 1}
          </Button>
          <Button size="sm" variant="ghost" onClick={() => model.discardRecoveryDraft(draft)}>
            {t('common.discard')}
          </Button>
        </div>
      ))}
    </div>
  )
}

function xmlToMarkdown(xml: string): string {
  try {
    return printMarkdown(parseXml(xml)).trim()
  } catch {
    return xml.trim()
  }
}

export function downloadDraft(
  xml: string,
  title?: string,
  recoveryDrafts?: readonly string[],
  properties?: { entries: readonly { key: string; source: string }[] }
) {
  const parts: string[] = []
  const heading = title?.trim()
  if (heading) parts.push(`# ${heading}`)
  if (properties) {
    parts.push(
      `## ${t('pod.knowledge.properties')}\n\n\`\`\`json\n${JSON.stringify(properties.entries, null, 2)}\n\`\`\``
    )
  }
  const body = xmlToMarkdown(xml)
  if (body) parts.push(body)
  recoveryDrafts?.forEach((draft, index) => {
    const kept = xmlToMarkdown(draft)
    if (kept) parts.push(`---\n\n## ${t('pod.content.export_kept_draft')} ${index + 1}\n\n${kept}`)
  })
  downloadBlob(
    new Blob([`${parts.join('\n\n')}\n`], { type: 'text/markdown;charset=utf-8' }),
    documentFilename(heading ?? '', 'document-draft')
  )
}
