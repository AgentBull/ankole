import type { RuntimeBrainSnapshot, RuntimeBrainSnapshotEntry } from '../lanes/rpc_lane'

/** Renders the control-plane-frozen Brain context shared by all model entrypoints. */
export function formatBrainSnapshot(snapshot: RuntimeBrainSnapshot | undefined): string {
  const entries = [
    snapshotEntry('agent_system_pinned_memo', snapshot?.pinned_memo),
    snapshotEntry('channel_entry', snapshot?.channel_entry)
  ].filter(Boolean)
  if (entries.length === 0) return ''

  return [
    '<brain_snapshot frozen="true">',
    'This is the Brain snapshot captured when this conversation started. It stays unchanged for this conversation.',
    ...entries,
    '</brain_snapshot>'
  ].join('\n')
}

function snapshotEntry(tag: string, entry: RuntimeBrainSnapshotEntry | null | undefined): string {
  if (!entry) return ''
  const attributes = [
    `entry_id="${escapeAttribute(entry.entry_id)}"`,
    `name="${escapeAttribute(entry.name)}"`,
    `truncated="${entry.truncated}"`,
    entry.store ? `store="${escapeAttribute(entry.store)}"` : '',
    entry.type ? `type="${escapeAttribute(entry.type)}"` : '',
    typeof entry.lock_version === 'number' ? `lock_version="${entry.lock_version}"` : ''
  ].filter(Boolean)
  return [`<${tag} ${attributes.join(' ')}>`, entry.markdown, `</${tag}>`].join('\n')
}

function escapeAttribute(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}
