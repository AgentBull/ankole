import { Button, toast } from '@ankole/uikit'
import { RiCheckLine, RiFileCopyLine, RiFileTextLine } from '@remixicon/react'
import { Link } from '@tanstack/react-router'
import {
  Children,
  createContext,
  isValidElement,
  lazy,
  Suspense,
  useContext,
  useEffect,
  useRef,
  useState,
  type HTMLAttributes,
  type ReactNode
} from 'react'
import { useTranslation } from 'react-i18next'
import Markdown, { defaultUrlTransform, type Components } from 'react-markdown'
import remarkGfm from 'remark-gfm'
import remarkMath from 'remark-math'
import rehypeKatex from 'rehype-katex'
import 'katex/dist/katex.min.css'
import { podLocation, podRouteID } from '../../common/browser-context'
import { ErrorBoundary } from '../../common/error-boundary'
import {
  EXTERNAL_TRANSLATION_GUARD_ATTRS,
  withExternalTranslationGuardClass
} from '../../common/external-translation-guard'
import { CodeBlockView } from './code-block-view'
import { ZoomableImage } from './zoomable-image'
import { cjkAutolinks } from './cjk-autolinks'
import { repairGeneratedMarkdown } from './repair-generated-markdown'

const LazyMermaidDiagram = lazy(() => import('./mermaid/mermaid-diagram'))
const StreamingMarkdownContext = createContext(false)

const HUMAN_REMARK_PLUGINS = [remarkGfm, remarkMath, cjkAutolinks]
const AGENT_REMARK_PLUGINS = [remarkGfm, remarkMath, repairGeneratedMarkdown, cjkAutolinks]

export default function MarkdownRenderer({
  text,
  generated = false,
  streaming = false
}: {
  text: string
  generated?: boolean
  streaming?: boolean
}) {
  return (
    <StreamingMarkdownContext.Provider value={streaming}>
      <Markdown
        remarkPlugins={generated ? AGENT_REMARK_PLUGINS : HUMAN_REMARK_PLUGINS}
        rehypePlugins={[rehypeKatex]}
        components={components}
        urlTransform={url => (url.startsWith('ankole:page/') ? url : defaultUrlTransform(url))}>
        {text}
      </Markdown>
    </StreamingMarkdownContext.Provider>
  )
}

function CodeBlock({ children }: { children?: ReactNode }) {
  const streaming = useContext(StreamingMarkdownContext)
  const child = Children.toArray(children).find(isValidElement)
  if (!isValidElement<{ children?: ReactNode; className?: string }>(child)) return <pre>{children}</pre>
  const language = /language-([^\s]+)/.exec(child.props.className ?? '')?.[1]
  const code = String(child.props.children ?? '').replace(/\n$/, '')
  if (language?.toLowerCase() === 'mermaid') {
    const fallback = <CodeBlockView code={code} language="mermaid" />
    return (
      <ErrorBoundary resetKeys={[code]} fallback={fallback}>
        <Suspense fallback={fallback}>
          <LazyMermaidDiagram code={code} streaming={streaming} />
        </Suspense>
      </ErrorBoundary>
    )
  }
  return <CodeBlockView code={code} language={language} />
}

function Table({ children }: { children?: ReactNode }) {
  const { t } = useTranslation()
  const table = useRef<HTMLTableElement>(null)
  const [copied, setCopied] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout>>(undefined)
  useEffect(() => () => clearTimeout(timer.current), [])
  return (
    <div className="my-3">
      <div className="flex justify-end">
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
      <div className="overflow-x-auto">
        <table ref={table} className="w-full border-collapse">
          {children}
        </table>
      </div>
    </div>
  )
}

// Each block takes its direction from its own first strong character, so an Arabic or Hebrew paragraph reads
// right to left inside an otherwise left-to-right reply.
const directional = (Tag: 'p' | 'li' | 'h1' | 'h2' | 'h3' | 'h4' | 'h5' | 'h6' | 'blockquote') =>
  function DirectionalBlock({ node: _node, ...props }: HTMLAttributes<HTMLElement> & { node?: unknown }) {
    return <Tag dir="auto" {...props} />
  }

const components: Components = {
  p: directional('p'),
  li: directional('li'),
  h1: directional('h1'),
  h2: directional('h2'),
  h3: directional('h3'),
  h4: directional('h4'),
  h5: directional('h5'),
  h6: directional('h6'),
  blockquote: directional('blockquote'),
  a: ({ children, href }) => {
    if (!href) return <span>{children}</span>
    if (href.startsWith('ankole:page/')) {
      const page = podRouteID(href.slice('ankole:page/'.length))
      return page ? (
        <Link
          {...EXTERNAL_TRANSLATION_GUARD_ATTRS}
          className={withExternalTranslationGuardClass('pod-chat-page-pill')}
          to={podLocation(`/pages/${page}`).pathname}>
          <RiFileTextLine aria-hidden />
          {children}
        </Link>
      ) : (
        <span>{children}</span>
      )
    }
    return (
      <a
        {...EXTERNAL_TRANSLATION_GUARD_ATTRS}
        href={href}
        target="_blank"
        rel="noreferrer"
        className={withExternalTranslationGuardClass('link')}>
        {children}
      </a>
    )
  },
  span: ({ node: _node, className, ...props }) =>
    typeof className === 'string' && /(?:^|\s)katex(?:-display)?(?:\s|$)/.test(className) ? (
      <span {...EXTERNAL_TRANSLATION_GUARD_ATTRS} className={withExternalTranslationGuardClass(className)} {...props} />
    ) : (
      <span className={className} {...props} />
    ),
  code: ({ node: _node, className, ...props }) => (
    <code {...EXTERNAL_TRANSLATION_GUARD_ATTRS} className={withExternalTranslationGuardClass(className)} {...props} />
  ),
  img: ({ src, alt }) => (typeof src === 'string' && src ? <ZoomableImage src={src} alt={alt} /> : <span>{alt}</span>),
  pre: CodeBlock,
  table: Table,
  th: ({ children, style }) => (
    <th dir="auto" className="content-cell content-cell-head text-start align-top" style={style}>
      {children}
    </th>
  ),
  td: ({ children, style }) => (
    <td dir="auto" className="content-cell text-start align-top" style={style}>
      {children}
    </td>
  )
}
