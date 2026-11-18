import { diffLines } from 'diff'
import { parseXml, printMarkdown } from '@ankole/block-editor/document'

export type VersionTime = { id: string; reason: string; created_at: string; document_updated_at: string }

/** Checkpoints describe saved content; restore entries describe an explicit operation. */
export function versionTime(version: Omit<VersionTime, 'id'>): string {
  return version.reason === 'before_restore' || version.reason === 'restored'
    ? version.created_at
    : version.document_updated_at
}

/** Adjacent versions that share a minute show their seconds, so two saves in one minute stay distinguishable. */
export function versionsShowingSeconds(versions: VersionTime[]): Set<string> {
  const minute = (version: VersionTime) => Math.floor(Date.parse(versionTime(version)) / 60_000)
  return new Set(
    versions
      .filter((version, index) =>
        [versions[index - 1], versions[index + 1]].some(other => other && minute(other) === minute(version))
      )
      .map(version => version.id)
  )
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
  // Markdown output has no final newline, so the last line otherwise differs from the same line followed by more text.
  return diffLines(before, current, { ignoreNewlineAtEof: true }).map(change => ({
    kind: change.added ? ('added' as const) : change.removed ? ('removed' as const) : ('unchanged' as const),
    text: change.value
  }))
}
