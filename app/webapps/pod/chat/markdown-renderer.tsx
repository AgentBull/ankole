import { Button, toast } from '@ankole/uikit'
import { RiCheckLine, RiFileCopyLine, RiFileTextLine } from '@remixicon/react'
import { Link } from '@tanstack/react-router'
import { Children, isValidElement, useEffect, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import Markdown, { defaultUrlTransform, type Components } from 'react-markdown'
import remarkGfm from 'remark-gfm'
import remarkMath from 'remark-math'
import rehypeKatex from 'rehype-katex'
import 'katex/dist/katex.min.css'
import { podLocation, podRouteID } from '../../common/browser-context'
import { CodeBlockView } from './code-block-view'
import { ZoomableImage } from './zoomable-image'
import { cjkAutolinks } from './cjk-autolinks'

export default function MarkdownRenderer({ text }: { text: string }) {
  return (
    <Markdown
      remarkPlugins={[remarkGfm, remarkMath, cjkAutolinks]}
      rehypePlugins={[rehypeKatex]}
      components={components}
      urlTransform={url => (url.startsWith('ankole:page/') ? url : defaultUrlTransform(url))}>
      {text}
    </Markdown>
  )
}

function CodeBlock({ children }: { children?: ReactNode }) {
  const child = Children.toArray(children).find(isValidElement)
  if (!isValidElement<{ children?: ReactNode; className?: string }>(child)) return <pre>{children}</pre>
  const language = /language-([^\s]+)/.exec(child.props.className ?? '')?.[1]
  return <CodeBlockView code={String(child.props.children ?? '').replace(/\n$/, '')} language={language} />
}

function Table({ children }: { children?: ReactNode }) {
  const { t } = useTranslation()
  const table = useRef<HTMLTableElement>(null)
  const [copied, setCopied] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)
  useEffect(() => () => clearTimeout(timer.current), [])
  return (
    <div className="pod-chat-table">
      <div className="pod-chat-table-tools">
        <Button
          variant="ghost"
          size="xs"
          onClick={async () => {
            const text = Array.from(table.current?.rows ?? [])
              .map(row =>
                Array.from(row.cells)
                  .map(cell => cell.textContent?.replace(/\s+/g, ' ').trim())
                  .join('\t')
              )
              .join('\n')
            try {
              await navigator.clipboard.writeText(text)
              setCopied(true)
              clearTimeout(timer.current)
              timer.current = setTimeout(() => setCopied(false), 1500)
              toast.success(t('pod.chat_timeline.copied'))
            } catch {
              toast.error(t('pod.chat.copy_failed'))
            }
          }}>
          {copied ? <RiCheckLine aria-hidden /> : <RiFileCopyLine aria-hidden />}
          {t(copied ? 'pod.chat_timeline.copied' : 'pod.chat_timeline.copy_table')}
        </Button>
      </div>
      <div className="pod-chat-table-scroll">
        <table ref={table}>{children}</table>
      </div>
    </div>
  )
}

const components: Components = {
  a: ({ children, href }) => {
    if (!href) return <span>{children}</span>
    if (href.startsWith('ankole:page/')) {
      const page = podRouteID(href.slice('ankole:page/'.length))
      return page ? (
        <Link className="pod-chat-page-pill" to={podLocation(`/pages/${page}`).pathname}>
          <RiFileTextLine aria-hidden />
          {children}
        </Link>
      ) : (
        <span>{children}</span>
      )
    }
    return (
      <a href={href} target="_blank" rel="noreferrer" className="link">
        {children}
      </a>
    )
  },
  img: ({ src, alt }) => (typeof src === 'string' && src ? <ZoomableImage src={src} alt={alt} /> : <span>{alt}</span>),
  pre: CodeBlock,
  table: Table
}
