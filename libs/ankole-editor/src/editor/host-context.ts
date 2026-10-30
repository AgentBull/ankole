import type { ReactNode } from 'react'
import type { UploadedAsset } from '../document/resources'
import type { Wordgard } from '../core/editor'
import { GardState } from '../core/state'
import type { MentionCategory } from './mention'
import type { MentionTarget } from './schema'
import type { CommentSelection } from './comments'

export type EmbedAttributes = { ref?: string; table?: string; view?: string }

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
}

export type EditorHost = {
  mountEmbed?(
    attributes: EmbedAttributes,
    container: HTMLElement,
    update: (attributes: EmbedAttributes) => void,
    remove: () => void
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
