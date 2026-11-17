import type { TFunction } from 'i18next'
import { parseFileCommentAnchor, formatFileAnchorLabel, type FileCommentAnchor } from './file-comment-anchors'
import { parseAppletElementAnchor, type AppletElementAnchor } from './applet-elements'

export type PageElementAnchor = FileCommentAnchor | AppletElementAnchor
export function parsePageElementAnchor(raw: Record<string, unknown> | null | undefined): PageElementAnchor | null {
  return raw ? (parseAppletElementAnchor(raw) ?? parseFileCommentAnchor(raw)) : null
}
export function formatPageElementAnchor(anchor: PageElementAnchor, t: TFunction): string {
  return anchor.kind === 'applet_element'
    ? [anchor.component, anchor.source].filter(Boolean).join(' · ') || `v${anchor.revision}`
    : formatFileAnchorLabel(anchor, t)
}
