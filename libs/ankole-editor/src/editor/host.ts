import { Elt } from '../core/doc'
import { Wordgard, Decoration } from '../core/editor'
import { Widget } from '../core/editor/decoration'
import type { GardState } from '../core/state'
import * as T from '../core/types'
import { Embed, embed as embedBlock, embedAttributes } from '../blocks/embed'
import { element } from '../document/tree'
import { markValue } from './attributes'
import { ImageTitle } from './schema'

export type EmbedAttributes = { ref?: string; table?: string; view?: string }
export type EditorHost = {
  mountEmbed?(
    attributes: EmbedAttributes,
    container: HTMLElement,
    update: (attributes: EmbedAttributes) => void
  ): void | (() => void)
  resolveAsset?(address: string): string
  openPage?(id: string): void
  /** Only the block-menu action calls this. Selection edits only remove the reference. */
  deleteEmbed?(id: string): Promise<boolean>
}

const hosts = new WeakMap<Wordgard, EditorHost>()
export const editorHost = (editor: Wordgard) => hosts.get(editor)

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
      const dispose = host.mountEmbed?.(attributes, dom as HTMLElement, next => {
        const editor = editors.get(dom as Element)!
        if (editor.state.readOnly) return
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
      })
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
    Wordgard.domEventHandler('click', event => {
      const link = (event.target as Element | null)?.closest('a[href^="ankole:page/"]')
      if (!link || !host.openPage) return false
      event.preventDefault()
      host.openPage(link.getAttribute('href')!.slice('ankole:page/'.length))
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
