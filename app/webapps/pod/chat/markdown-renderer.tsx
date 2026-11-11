import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import { Button, toast } from '@ankole/uikit'
import { CheckmarkRegular, CopyRegular } from '@ankole/uikit/icons'
import {
  Children,
  createContext,
  Fragment,
  isValidElement,
  lazy,
  Suspense,
  useContext,
  useMemo,
  useRef,
  useState,
  type HTMLAttributes,
  type ReactNode
} from 'react'
import { useTranslation } from 'react-i18next'
import Markdown, { defaultUrlTransform, type Components, type Options } from 'react-markdown'
import remarkMath from 'remark-math'
import rehypeKatex from 'rehype-katex'
import 'katex/dist/katex.min.css'
import { podRouteID } from '../../common/browser-context'
import { ErrorBoundary } from '../../common/error-boundary'
import { MARKDOWN_SYNTAX_PLUGINS } from '../../common/markdown-syntax'
import { PageReferenceCard } from '../message-artifacts'
import {
  EXTERNAL_TRANSLATION_GUARD_ATTRS,
  withExternalTranslationGuardClass
} from '../../common/external-translation-guard'
import { CodeBlockView } from './code-block-view'
import { ZoomableImage } from './zoomable-image'
import { cjkAutolinks } from './cjk-autolinks'
import { MATH_OPTIONS, repairGeneratedMarkdown } from './repair-generated-markdown'

const LazyMermaidDiagram = lazy(() => import('./mermaid/mermaid-diagram'))
const LazyUIBlock = lazy(() => import('./ui-block/ui-block'))
const StreamingMarkdownContext = createContext(false)
const RevealWordsContext = createContext(false)
/** Set for an Agent's message, whose `ui` blocks render; a Human's fenced `ui` block stays code. */
const UIBlocksContext = createContext<{ onReply?: (text: string) => void } | null>(null)

type HastNode = {
  type: string
  tagName?: string
  value?: string
  properties?: Record<string, unknown>
  children?: HastNode[]
}

const isPageReference = (node: HastNode) =>
  node.type === 'element' &&
  node.tagName === 'a' &&
  typeof node.properties?.href === 'string' &&
  node.properties.href.startsWith('ankole:page/')

/**
 * A Page reference stands in its text 6px from the words beside it. When a reference opens or closes its block, no
 * words stand on that side, so this plugin marks the side (`data-leading`, `data-trailing`) and the chat's styles
 * keep the reference flush with the block's edge there.
 */
function markPageReferenceEdges() {
  const blank = (node: HastNode | undefined) => !node || (node.type === 'text' && !node.value?.trim())
  const visit = (node: HastNode) => {
    const children = node.children ?? []
    children.forEach((child, index) => {
      if (isPageReference(child)) {
        const before = children.slice(0, index).every(sibling => blank(sibling))
        const after = children.slice(index + 1).every(sibling => blank(sibling))
        child.properties = {
          ...child.properties,
          ...(before && { dataLeading: '' }),
          ...(after && { dataTrailing: '' })
        }
      }
      visit(child)
    })
  }
  return (tree: HastNode) => visit(tree)
}

const REHYPE_PLUGINS: Options['rehypePlugins'] = [rehypeKatex, markPageReferenceEdges]

const HUMAN_REMARK_PLUGINS: Options['remarkPlugins'] = [
  ...MARKDOWN_SYNTAX_PLUGINS,
  [remarkMath, MATH_OPTIONS],
  cjkAutolinks
]
const AGENT_REMARK_PLUGINS: Options['remarkPlugins'] = [
  ...MARKDOWN_SYNTAX_PLUGINS,
  [remarkMath, MATH_OPTIONS],
  repairGeneratedMarkdown,
  cjkAutolinks
]

export default function MarkdownRenderer({
  text,
  generated = false,
  streaming = false,
  reveal = false,
  onReply
}: {
  text: string
  generated?: boolean
  streaming?: boolean
  reveal?: boolean
  onReply?: (text: string) => void
}) {
  const uiBlocks = useMemo(() => (generated ? { onReply } : null), [generated, onReply])
  const markdown = (
    <Markdown
      remarkPlugins={generated ? AGENT_REMARK_PLUGINS : HUMAN_REMARK_PLUGINS}
      rehypePlugins={REHYPE_PLUGINS}
      components={components}
      urlTransform={url => (url.startsWith('ankole:page/') ? url : defaultUrlTransform(url))}>
      {text}
    </Markdown>
  )
  return (
    <StreamingMarkdownContext.Provider value={streaming}>
      <UIBlocksContext.Provider value={uiBlocks}>
        <RevealWordsContext.Provider value={reveal}>{markdown}</RevealWordsContext.Provider>
      </UIBlocksContext.Provider>
    </StreamingMarkdownContext.Provider>
  )
}

function CodeBlock({ children }: { children?: ReactNode }) {
  const streaming = useContext(StreamingMarkdownContext)
  const uiBlocks = useContext(UIBlocksContext)
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
  if (normalizedLang === 'ui' && uiBlocks) {
    const fallback = <CodeBlockView code={code} language="ui" />
    return (
      <ErrorBoundary resetKeys={[code]} fallback={fallback}>
        <Suspense fallback={streaming ? null : fallback}>
          <LazyUIBlock code={code} streaming={streaming} onReply={uiBlocks.onReply} />
        </Suspense>
      </ErrorBoundary>
    )
  }
  return <CodeBlockView code={code} language={language} />
}

/**
 * A reply's table in its block card. Its copy control stands inside the table's top corner, over the end of the
 * header row, and shows while the pointer is over the table or the focus is on the control, so a table at rest
 * is only its data.
 */
function Table({ children }: { children?: ReactNode }) {
  const { t } = useTranslation()
  const table = useRef<HTMLTableElement>(null)
  const [copied, markCopied] = useCopyFeedback(false)
  const label = t(copied ? 'pod.chat_timeline.copied' : 'pod.chat_timeline.copy_table')
  return (
    <div className="pod-chat-table-frame">
      <div className="pod-chat-table surface-block overflow-x-auto">
        <table ref={table} className="w-full border-collapse border-hidden">
          {children}
        </table>
      </div>
      <Button
        variant="ghost"
        size="icon-xs"
        className="pod-chat-table-copy"
        data-copied={copied || undefined}
        aria-label={label}
        title={label}
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
        {copied ? <CheckmarkRegular aria-hidden /> : <CopyRegular aria-hidden />}
      </Button>
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

function MarkdownAnchor({
  children,
  href,
  'data-leading': leading,
  'data-trailing': trailing
}: {
  children?: ReactNode
  href?: string
  'data-leading'?: string
  'data-trailing'?: string
}) {
  if (!href) return <span>{children}</span>
  if (href.startsWith('ankole:page/')) {
    const page = podRouteID(href.slice('ankole:page/'.length))
    // A Page reference is the reference card wherever it stands, here on the line of the text that names it.
    return page ? (
      <PageReferenceCard
        {...EXTERNAL_TRANSLATION_GUARD_ATTRS}
        data-leading={leading}
        data-trailing={trailing}
        className={withExternalTranslationGuardClass('pod-chat-inline-reference')}
        id={page}
        title={children}
      />
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
