import { Elt } from '../core/doc'
import { Wordgard, Decoration } from '../core/editor'
import { Widget } from '../core/editor/decoration'
import type { GardState } from '../core/state'
import * as T from '../core/types'
import { Embed, embed as embedBlock, embedAttributes } from '../blocks/embed'
import { element } from '../document/tree'
import { markValue } from './attributes'
import { deleteBlock } from './block-actions'
import { dispatchStep } from './block-insert'
import { ImageTitle } from './schema'

export type EmbedAttributes = { ref?: string; table?: string; view?: string }
export type EditorHost = {
  mountEmbed?(
    attributes: EmbedAttributes,
    container: HTMLElement,
    update: (attributes: EmbedAttributes) => void,
    remove: () => void
  ): void | (() => void)
  resolveAsset?(address: string): string
  openPage?(id: string): void
  /** Only the block-menu action calls this. Selection edits only remove the reference. */
  deleteEmbed?(id: string): Promise<boolean>
}

const hosts = new WeakMap<Wordgard, EditorHost>()
export const editorHost = (editor: Wordgard) => hosts.get(editor)

/** Open a safe link address through the host or the browser. */
export function openLinkHref(editor: Wordgard, href: string): boolean {
  const host = editorHost(editor)
  if (href.startsWith('ankole:page/')) {
    if (!host?.openPage) return false
    host.openPage(href.slice('ankole:page/'.length))
    return true
  }
  if (!/^(https?:\/\/|mailto:|tel:|\/|#)/i.test(href) || typeof window === 'undefined') return false
  if (href.startsWith('#')) {
    window.location.hash = href
    return true
  }
  window.open(href, '_blank', 'noopener,noreferrer')
  return true
}

/** The host owns embedded resources. The editor owns their reference and DOM lifecycle. */
export function hostExtension(host: EditorHost): GardState.Extension {
  const cleanup = new WeakMap<Element, () => void>()
  const editors = new WeakMap<Element, Wordgard>()
  const embed = Widget.define<EmbedAttributes>({
    render: (_attributes, editor) => {
      const container = document.createElement('div')
      container.className = 'embed'
      editors.set(container, editor)
      return container
    },
    connect: (attributes, dom) => {
      const update = (next: EmbedAttributes) => {
        const editor = editors.get(dom as Element)
        if (!editor || editor.state.readOnly) return
        const position = editor.posAtDOM(dom)
        const node = editor.state.doc.resolve(position).nodeAfter
        if (node?.type !== Embed.type) return
        editor.dispatch({
          changes: {
            from: position,
            to: position + node.length,
            insert: [
              embedBlock.import(
                element(
                  'embed',
                  Object.fromEntries(
                    Object.entries(next).filter((item): item is [string, string] => item[1] !== undefined)
                  )
                ),
                { blocks: () => [] }
              )
            ]
          },
          userEvent: 'embed.configure'
        })
      }
      const remove = () => {
        const editor = editors.get(dom as Element)
        if (!editor || editor.state.readOnly) return
        const position = editor.posAtDOM(dom)
        const found = editor.state.doc.resolveNode(position)
        if (found?.node.type !== Embed.type) return
        if (!found.parent?.parent) deleteBlock(editor, position)
        else {
          dispatchStep(editor, {
            changes: { from: position, to: position + found.node.length },
            userEvent: 'block.delete'
          })
        }
        editor.focus()
      }
      const dispose = host.mountEmbed?.(attributes, dom as HTMLElement, update, remove)
      if (dispose) cleanup.set(dom as Element, dispose)
    },
    disconnect: (_attributes, dom) => {
      cleanup.get(dom as Element)?.()
      cleanup.delete(dom as Element)
    },
    propagateEvent: false
  })
  return [
    host.mountEmbed ? Decoration.Tag.shape(Embed, tag => embed.of(embedAttributes(tag))) : [],
    host.resolveAsset
      ? Decoration.Tag.shape(T.Image, tag =>
          Elt.mk('img', {
            src: host.resolveAsset!(tag.param),
            alt: markValue(tag, T.ImageAlt) ?? '',
            title: markValue(tag, ImageTitle) ?? ''
          })
        )
      : [],
    Wordgard.domEventHandler('click', (event, editor) => {
      if (event.button !== 0) return false
      const link = (event.target as Element | null)?.closest('a[href]')
      if (!link) return false
      const href = link.getAttribute('href') ?? ''
      if (href.startsWith('ankole:page/')) {
        if (!host.openPage) return false
        event.preventDefault()
        host.openPage(href.slice('ankole:page/'.length))
        return true
      }
      if (!editor.state.readOnly && !event.metaKey && !event.ctrlKey) return false
      if (!openLinkHref(editor, href)) return false
      event.preventDefault()
      return true
    })
  ]
}

export function attachHost(editor: Wordgard, host?: EditorHost) {
  if (host) hosts.set(editor, host)
  return () => {
    hosts.delete(editor)
  }
}
