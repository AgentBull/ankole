import { createElement, useEffect, useMemo, useRef, type CSSProperties, type ReactNode } from 'react'
import { parseXml } from '../document/xml'
import { validateKnowledge } from '../document/knowledge'
import { assetURL, safeLinkHref } from '../document/resources'
import type { Element, Node } from '../document/tree'
import type { EditorHost } from '../editor/host-context'
import type { MentionTarget } from '../editor/schema'

type ReaderHost = Pick<EditorHost, 'resolveAsset' | 'mountMention' | 'mentionText' | 'openPage'>

export type KnowledgeReaderProps = {
  xml: string
  host?: ReaderHost
  pageHref?: (id: string) => string
  className?: string
}

const textOf = (node: Node): string => (node.type === 'text' ? node.value : node.children.map(textOf).join(''))

function hasContent(node: Node): boolean {
  if (node.type === 'text') return node.value.trim().length > 0
  if (['p', 'strong', 'em', 's', 'code', 'a', 'br'].includes(node.name)) return node.children.some(hasContent)
  return true
}

function Mention({ target, host }: { target: MentionTarget; host?: ReaderHost }) {
  const container = useRef<HTMLSpanElement>(null)
  const page = 'page' in target ? target.page : undefined
  const principal = 'principal' in target ? target.principal : undefined
  useEffect(() => {
    if (!container.current || !host?.mountMention) return
    // A host may unmount its React root asynchronously. Give each mount its own
    // container so a previous root cannot clear a newly resolved reference.
    const mount = document.createElement('span')
    container.current.append(mount)
    const dispose = host.mountMention(page ? { page } : { principal: principal! }, mount, {
      readOnly: true,
      openPage: host.openPage
    })
    return () => {
      dispose?.()
      mount.remove()
    }
  }, [host, page, principal])
  return (
    <span className="editor-mention" ref={container}>
      {host?.mountMention ? undefined : host?.mentionText?.(target) || page || `@${principal}`}
    </span>
  )
}

/** Displays the canonical knowledge vocabulary without creating an editor or an editable DOM. */
export function KnowledgeReader({ xml, host, pageHref, className = '' }: KnowledgeReaderProps) {
  const page = useMemo(() => validateKnowledge(parseXml(xml)), [xml])
  if (!page.children.some(hasContent)) return null

  function render(node: Node, key: number): ReactNode {
    if (node.type === 'text') return node.value
    const children = node.children.map(render)
    const attrs = node.attrs
    switch (node.name) {
      case 'br':
      case 'hr':
        return createElement(node.name, { key })
      case 'mention':
        return (
          <Mention key={key} target={attrs.page ? { page: attrs.page } : { principal: attrs.principal! }} host={host} />
        )
      case 'a': {
        const address = safeLinkHref(attrs.href || '')
        const pageID = address?.startsWith('ankole:page/') ? address.slice('ankole:page/'.length) : undefined
        const href = pageID
          ? pageHref?.(pageID) || address
          : address?.startsWith('ankole:asset/')
            ? assetURL(address, host?.resolveAsset)
            : address
        return (
          <a
            key={key}
            href={href || undefined}
            title={attrs.title}
            target={pageID || href?.startsWith('#') ? undefined : '_blank'}
            rel="noopener noreferrer"
            onClick={event => {
              if (
                pageID &&
                host?.openPage &&
                !event.button &&
                !event.metaKey &&
                !event.ctrlKey &&
                !event.shiftKey &&
                !event.altKey
              ) {
                event.preventDefault()
                host.openPage(pageID)
              }
            }}>
            {children}
          </a>
        )
      }
      case 'img':
      case 'media': {
        const src = assetURL(attrs.src || '', host?.resolveAsset)
        const image = src ? (
          <a href={src} target="_blank" rel="noopener noreferrer">
            <img src={src} alt={attrs.alt || attrs.title || ''} title={attrs.title} loading="lazy" decoding="async" />
          </a>
        ) : (
          attrs.alt || attrs.title || null
        )
        return node.name === 'media' ? (
          <figure key={key}>
            {image}
            {(attrs.title || attrs.description) && <figcaption>{attrs.description || attrs.title}</figcaption>}
          </figure>
        ) : (
          <span key={key}>{image}</span>
        )
      }
      case 'callout':
        return (
          <aside key={key} className="callout" data-tone={attrs.tone}>
            <span className="callout-icon" aria-hidden="true">
              {attrs.icon || '💡'}
            </span>
            <div className="callout-content">{children}</div>
          </aside>
        )
      case 'pre':
        return (
          <div key={key} className="editor-code-block">
            {attrs.lang && (
              <div className="editor-code-toolbar">
                <span>{attrs.lang}</span>
              </div>
            )}
            <pre className="code-text">
              <code>{textOf(node)}</code>
            </pre>
          </div>
        )
      case 'table': {
        const rows = node.children.filter((child): child is Element => child.type === 'element')
        return (
          <div
            key={key}
            className="table-block"
            style={{ '--table-min-width': `${(rows[0]?.children.length || 0) * 80}px` } as CSSProperties}>
            <div className="table-scroll" tabIndex={0}>
              <table>
                <thead>{rows.slice(0, 1).map(render)}</thead>
                <tbody>{rows.slice(1).map(render)}</tbody>
              </table>
            </div>
          </div>
        )
      }
      case 'th':
      case 'td':
        return createElement(
          node.name,
          { key, scope: node.name === 'th' ? 'col' : undefined, style: { textAlign: attrs.align } as CSSProperties },
          children
        )
      case 'ol':
        return (
          <ol key={key} start={attrs.start === undefined ? undefined : Number(attrs.start)}>
            {children}
          </ol>
        )
      case 'li':
        return (
          <li key={key} data-task={attrs.task}>
            {attrs.task && (
              <input
                className="sr-only"
                type="checkbox"
                checked={attrs.task === 'done'}
                disabled
                aria-label={textOf(node)}
              />
            )}
            {children}
          </li>
        )
      default:
        return createElement(node.name, { key }, children)
    }
  }

  return (
    <article className={`ankole-editor knowledge-reader ${className}`} data-knowledge-reader>
      <div className="editor-content">{page.children.map(render)}</div>
    </article>
  )
}
