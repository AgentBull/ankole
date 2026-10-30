import { editorHost, hostFacet, type EditorHost, type EmbedAttributes } from './host-context'
import { resourceWidget } from '../blocks/resources'
import { Elt } from '../core/doc'
import { Wordgard, Decoration } from '../core/editor'
import { Widget } from '../core/editor/decoration'
import { GardState } from '../core/state'
import * as T from '../core/types'
import { Embed, embed as embedBlock, embedAttributes } from '../blocks/embed'
import { assetURL } from '../document/resources'
import { element } from '../document/tree'
import { markValue } from './attributes'
import { deleteBlock } from './block-actions'
import { dispatchStep } from './block-insert'
import { ImageTitle, Mention, safeLinkHref, sameMentionTarget, type MentionTarget } from './schema'

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
                { blocks: () => [], code: () => [] }
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
  const mention = Widget.define<MentionTarget>({
    eq: sameMentionTarget,
    render: (target, editor) => {
      const span = document.createElement('span')
      span.contentEditable = 'false'
      if ('page' in target) {
        span.className = 'editor-mention editor-mention-page'
        span.setAttribute('data-mention-page', target.page)
      } else {
        span.className = 'editor-mention editor-mention-principal'
        span.setAttribute('data-mention-principal', target.principal)
      }
      editors.set(span, editor)
      return span
    },
    connect: (target, dom) => {
      const editor = editors.get(dom as Element)
      const dispose = host.mountMention?.(target, dom as HTMLElement, {
        readOnly: editor?.state.readOnly ?? true,
        openPage: host.openPage ? id => host.openPage!(id) : undefined
      })
      if (dispose) cleanup.set(dom as Element, dispose)
    },
    disconnect: (_target, dom) => {
      cleanup.get(dom as Element)?.()
      cleanup.delete(dom as Element)
    },
    propagateEvent: false
  })
  return [
    hostFacet.of(host),
    host.mountEmbed
      ? Decoration.Tag.shape(Embed, tag => {
          const attrs = embedAttributes(tag)
          return attrs.href !== undefined ? resourceWidget.of('embed') : embed.of(attrs)
        })
      : [],
    host.mountMention ? Decoration.Tag.shape(Mention, tag => mention.of(tag.param)) : [],
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
      if (event.defaultPrevented || event.button !== 0) return false
      if ((event.target as Element | null)?.closest('.editor-mention')) return false
      const anchor = (event.target as Element | null)?.closest('[data-comment-ids]')
      if (anchor && host.openComment) {
        host.openComment(anchor.getAttribute('data-comment-ids')!.split(' '))
        event.preventDefault()
        return true
      }
      const link = (event.target as Element | null)?.closest('a[href]')
      if (!link) return false
      const href = (link.getAttribute('href') ?? '').trim()
      if (href.startsWith('ankole:page/')) {
        event.preventDefault()
        host.openPage?.(href.slice('ankole:page/'.length))
        return true
      }
      if (!editor.state.readOnly && !event.metaKey && !event.ctrlKey) return false
      event.preventDefault()
      openLinkHref(editor, href)
      return true
    })
  ]
}
