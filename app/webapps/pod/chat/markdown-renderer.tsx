import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import { Button, toast } from '@ankole/uikit'
import { RiCheckLine, RiFileCopyLine, RiFileTextLine } from '@remixicon/react'
import { Link } from '@tanstack/react-router'
import {
  Children,
  createContext,
  Fragment,
  isValidElement,
  lazy,
  Suspense,
  useContext,
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
import { podRouteID } from '../../common/browser-context'
import { ErrorBoundary } from '../../common/error-boundary'
import { usePageHref } from '../use-page-metadata'
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
const RevealWordsContext = createContext(false)

const HUMAN_REMARK_PLUGINS = [remarkGfm, remarkMath, cjkAutolinks]
const AGENT_REMARK_PLUGINS = [remarkGfm, remarkMath, repairGeneratedMarkdown, cjkAutolinks]

export default function MarkdownRenderer({
  text,
  generated = false,
  streaming = false,
  reveal = false
}: {
  text: string
  generated?: boolean
  streaming?: boolean
  reveal?: boolean
}) {
  const markdown = (
    <Markdown
      remarkPlugins={generated ? AGENT_REMARK_PLUGINS : HUMAN_REMARK_PLUGINS}
      rehypePlugins={[rehypeKatex]}
      components={components}
      urlTransform={url => (url.startsWith('ankole:page/') ? url : defaultUrlTransform(url))}>
      {text}
    </Markdown>
  )
  return (
    <StreamingMarkdownContext.Provider value={streaming}>
      <RevealWordsContext.Provider value={reveal}>{markdown}</RevealWordsContext.Provider>
    </StreamingMarkdownContext.Provider>
  )
}

function CodeBlock({ children }: { children?: ReactNode }) {
  const streaming = useContext(StreamingMarkdownContext)
  const child = Children.toArray(children).find(isValidElement)
  if (!isValidElement<{ children?: ReactNode; className?: string }>(child)) return <pre>{children}</pre>
  const language = /language-([^\s]+)/.exec(child.props.className ?? '')?.[1]
  const code = String(child.props.children ?? '').replace(/\n$/, '')
  const normalizedLang = language?.toLowerCase()
  if (normalizedLang === 'mermaid' || normalizedLang === 'infographic') {
    const fallback = <CodeBlockView code={code} language={normalizedLang} />
    return (
      <ErrorBoundary resetKeys={[code, normalizedLang]} fallback={fallback}>
        <Suspense fallback={fallback}>
          <LazyMermaidDiagram code={code} streaming={streaming} kind={normalizedLang} />
        </Suspense>
      </ErrorBoundary>
    )
  }
  return <CodeBlockView code={code} language={language} />
}

function Table({ children }: { children?: ReactNode }) {
  const { t } = useTranslation()
  const table = useRef<HTMLTableElement>(null)
  const [copied, markCopied] = useCopyFeedback(false)
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
              markCopied(true)
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

type WordReveal = { text: string; words: { start: number; end: number; delay: number }[] }

const wordSegmenter = new Intl.Segmenter(undefined, { granularity: 'word' })

function appendedWords(previous: WordReveal, text: string): WordReveal {
  if (!text.startsWith(previous.text)) return { text, words: [] }
  const offset = previous.text.length
  const suffix = text.slice(offset)
  const appended = [...wordSegmenter.segment(suffix)].filter(part => part.isWordLike).slice(-12)
  const words = appended.map((word, index) => ({
    start: offset + word.index,
    end: offset + (appended[index + 1]?.index ?? suffix.length),
    delay: index * 26
  }))
  return { text, words: [...previous.words, ...words].slice(-12) }
}

function IncomingWords({ text }: { text: string }) {
  const [reveal, setReveal] = useState(() => appendedWords({ text: '', words: [] }, text))
  if (reveal.text !== text) setReveal(appendedWords(reveal, text))
  return (
    <>
      {text.slice(0, reveal.words[0]?.start)}
      {reveal.words.map(({ start, end, delay }, index) => (
        <Fragment key={start}>
          <span
            data-answer-word=""
            style={{ animationDelay: `${delay}ms` }}
            onAnimationEnd={
              index === reveal.words.length - 1
                ? event => {
                    const block = event.currentTarget.parentElement
                    const selection = block?.ownerDocument.getSelection()
                    if (
                      block &&
                      selection?.rangeCount &&
                      !selection.isCollapsed &&
                      selection.getRangeAt(0).intersectsNode(block)
                    ) {
                      return
                    }
                    setReveal(current => (current === reveal ? { text, words: [] } : current))
                  }
                : undefined
            }>
            {text.slice(start, end)}
          </span>
          {text.slice(end, reveal.words[index + 1]?.start)}
        </Fragment>
      ))}
    </>
  )
}

function proseChild(child: ReactNode, index = 0) {
  return typeof child === 'string' && child.trim() ? <IncomingWords key={index} text={child} /> : child
}

// Keep one parsed Markdown document. Reveal only the newest rendered prose, within its original block and direction.
const prose = (
  Tag: 'p' | 'li' | 'h1' | 'h2' | 'h3' | 'h4' | 'h5' | 'h6' | 'blockquote' | 'strong' | 'em' | 'del',
  dir?: 'auto'
) =>
  function Prose({ node: _node, children, ...props }: HTMLAttributes<HTMLElement> & { node?: unknown }) {
    const reveal = useContext(RevealWordsContext)
    return (
      <Tag dir={dir} {...props}>
        {reveal ? (Array.isArray(children) ? children.map(proseChild) : proseChild(children)) : children}
      </Tag>
    )
  }

function MarkdownAnchor({ children, href }: { children?: ReactNode; href?: string }) {
  const pageHref = usePageHref()
  if (!href) return <span>{children}</span>
  if (href.startsWith('ankole:page/')) {
    const page = podRouteID(href.slice('ankole:page/'.length))
    return page ? (
      <Link
        {...EXTERNAL_TRANSLATION_GUARD_ATTRS}
        className={withExternalTranslationGuardClass('pod-chat-page-pill')}
        to={pageHref(page)}>
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
}

const components: Components = {
  p: prose('p', 'auto'),
  li: prose('li', 'auto'),
  h1: prose('h1', 'auto'),
  h2: prose('h2', 'auto'),
  h3: prose('h3', 'auto'),
  h4: prose('h4', 'auto'),
  h5: prose('h5', 'auto'),
  h6: prose('h6', 'auto'),
  blockquote: prose('blockquote', 'auto'),
  strong: prose('strong'),
  em: prose('em'),
  del: prose('del'),
  a: MarkdownAnchor,
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
