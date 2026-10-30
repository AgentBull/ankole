import { diffLines } from 'diff'
import { parseXml, printMarkdown } from '@ankole/block-editor/document'

type VersionTime = { reason: string; created_at: string; document_updated_at: string }

/** Checkpoints describe saved content; restore entries describe an explicit operation. */
export function versionTime(version: VersionTime): string {
  return version.reason === 'before_restore' || version.reason === 'restored'
    ? version.created_at
    : version.document_updated_at
}

/** History keeps native layout and formatting that portable exports deliberately flatten. */
export function documentComparisonSource(xml: string, title: string): string {
  const page = parseXml(xml)
  if (title.trim()) {
    page.children.unshift({ type: 'element', name: 'h1', attrs: {}, children: [{ type: 'text', value: title }] })
  }
  return printMarkdown(page)
}

/** Compare the selected version with the current document. */
export function documentChanges(before: string, current: string) {
  return diffLines(before, current).map(change => ({
    kind: change.added ? ('added' as const) : change.removed ? ('removed' as const) : ('unchanged' as const),
    text: change.value
  }))
}
