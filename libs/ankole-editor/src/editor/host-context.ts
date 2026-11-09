import type { ReactNode } from 'react'
import { assetURL, safeLinkHref, type UploadedAsset } from '../document/resources'
import type { Wordgard } from '../core/editor'
import { GardState } from '../core/state'
import type { MentionCategory } from './mention'
import type { MentionTarget } from './schema'
import type { CommentSelection } from './comments'

export type EmbedAttributes = { ref?: string; table?: string; view?: string }

export type LinkMetadata = {
  url?: string
  title?: string
  description?: string
  image?: string
  icon?: string
}

export type MentionItem = {
  target: MentionTarget
  title: string
  subtitle?: string
  badge?: string
  icon?: ReactNode
  section?: string
  sectionCategory?: MentionCategory
}

export type MentionQueryResult = {
  items: readonly MentionItem[]
  /** Total matches across all categories (`all`), used for >12-char zero-match auto-dismiss. */
  totalAllMatches?: number
}

export type MountMentionOptions = {
  readOnly: boolean
  openPage?: (id: string) => void
  embedPage?: (id: string) => void
}

export type EditorHost = {
  mountEmbed?(
    attributes: EmbedAttributes,
    container: HTMLElement,
    update: (attributes: EmbedAttributes) => void,
    remove: () => void,
    collapseToMention?: () => void
  ): void | (() => void)
  mountMention?(target: MentionTarget, container: HTMLElement, options: MountMentionOptions): void | (() => void)
  queryMentions?(request: {
    query: string
    category: MentionCategory
    signal: AbortSignal
  }): Promise<MentionQueryResult> | MentionQueryResult
  /** Plain-text label for clipboard `text/plain` serialization of an inline `<mention />`. */
  mentionText?(target: MentionTarget): string | null
  /** Match a bare pasted internal page URL and return its page UUID, or `null` if external. */
  matchPageUrl?(url: string): string | null
  /** Describe an internal `ankole:page/<id>` link target for link toolbars and editing forms. */
  describePageLink?(id: string): { title?: string; href: string } | null
  /**
   * Whether a referenced internal page can switch between inline `<mention>` and block
   * `<embed ref>`. May return a `Promise<boolean>` while page metadata is still loading.
   */
  canEmbedPage?(id: string): boolean | Promise<boolean>
  /** Subscribe to host page metadata updates so inline page link and mention toolbars refresh reactively. */
  subscribePageLinks?(listener: () => void): () => void
  /** Resolve metadata (title, description, preview image, site icon) for an external HTTP or HTTPS URL. */
  resolveLinkMetadata?(url: string, signal?: AbortSignal): Promise<LinkMetadata | null> | LinkMetadata | null
  resolveAsset?(address: string): string
  /** Upload bytes once through the host and return a durable address and metadata. */
  uploadAsset?(file: File): Promise<UploadedAsset>
  /**
   * Accept files chosen from the `file` menu entry. The host stores them as its own resources and
   * the document stays unchanged. A rejection carries a message the upload panel shows.
   */
  acceptFiles?(files: readonly File[]): Promise<void>
  openPage?(id: string): void
  /** Open a persisted thread selected through its document anchor. */
  openComment?(ids: readonly string[]): void
  /** Ask the host to create a persisted thread for this selection. */
  requestComment?(selection: CommentSelection): void
  /** Ask the host to hand this selection to an Agent; the host owns the conversation that receives it. */
  askAgent?(selection: CommentSelection): void
  /** Atomically deletes the resources chosen by the block menu. Selection edits only remove references. */
  deleteEmbeds?(ids: readonly string[]): Promise<boolean>
  /** Ask the host to insert a chart block at the current selection. */
  insertChart?(editor: Wordgard): void
  /** Ask the host to pick and insert an internal page embed (`<embed ref="..." />`) at the current selection. */
  insertPageEmbed?(editor: Wordgard): void
}

export const hostFacet = GardState.Facet.define<EditorHost, EditorHost | undefined>({
  combine: values => values[0]
})

const hosts = new WeakMap<Wordgard, EditorHost>()
export const editorHost = (editor: Wordgard) => hosts.get(editor) ?? editor.state.facet(hostFacet)

export function attachHost(editor: Wordgard, host?: EditorHost) {
  if (host) hosts.set(editor, host)
  return () => {
    hosts.delete(editor)
  }
}

/** Open a safe link address through the host or the browser. */
export function openLinkHref(editor: Wordgard, href: string): boolean {
  const safe = safeLinkHref(href)
  if (!safe) return false
  const host = editorHost(editor)
  if (safe.startsWith('ankole:page/')) {
    if (!host?.openPage) return false
    host.openPage(safe.slice('ankole:page/'.length))
    return true
  }
  const target = safe.startsWith('ankole:asset/') ? assetURL(safe, host?.resolveAsset) : safe
  const allowedTarget = target ? safeLinkHref(target) : null
  if (!allowedTarget || allowedTarget.startsWith('ankole:') || typeof window === 'undefined') return false
  if (allowedTarget.startsWith('#')) {
    window.location.hash = allowedTarget
    return true
  }
  window.open(allowedTarget, '_blank', 'noopener,noreferrer')
  return true
}
