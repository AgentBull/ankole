'use client'

import { Button } from '@/uikit/components/button'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/uikit/components/select'
import { cn } from '@/uikit/lib/utils'
import { CheckIcon, CopyIcon } from 'lucide-react'
import type { ComponentProps, CSSProperties, HTMLAttributes } from 'react'
import { createContext, memo, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react'
import type { BundledLanguage, BundledTheme, HighlighterGeneric, ThemedToken } from 'shiki'
import { createHighlighter } from 'shiki'

// Shiki uses bitflags for font styles: 1=italic, 2=bold, 4=underline
// oxlint-disable-next-line eslint(no-bitwise)
const isItalic = (fontStyle: number | undefined) => fontStyle && fontStyle & 1
// oxlint-disable-next-line eslint(no-bitwise)
const isBold = (fontStyle: number | undefined) => fontStyle && fontStyle & 2
const isUnderline = (fontStyle: number | undefined) =>
  // oxlint-disable-next-line eslint(no-bitwise)
  fontStyle && fontStyle & 4

// Tokens have no natural id, and the array index is the only stable identity here (token order is fixed
// for a given snapshot). Precomputing the index-based key once keeps it out of the render JSX and
// satisfies the noArrayIndexKey lint rule, which forbids passing a raw index as `key` inline.
interface KeyedToken {
  token: ThemedToken
  key: string
}
interface KeyedLine {
  tokens: KeyedToken[]
  key: string
}

const addKeysToTokens = (lines: ThemedToken[][]): KeyedLine[] =>
  lines.map((line, lineIdx) => ({
    key: `line-${lineIdx}`,
    tokens: line.map((token, tokenIdx) => ({
      key: `line-${lineIdx}-${tokenIdx}`,
      token
    }))
  }))

// Renders one highlighted token. Light-theme colors come from inline styles below; in dark mode the
// className forces the CSS variables Shiki emits for its dark theme, so the same DOM serves both themes
// without re-tokenizing. Bit-flag font styles are translated to real CSS here.
const TokenSpan = ({ token }: { token: ThemedToken }) => (
  <span
    className="dark:!bg-[var(--shiki-dark-bg)] dark:!text-[var(--shiki-dark)]"
    style={
      {
        backgroundColor: token.bgColor,
        color: token.color,
        fontStyle: isItalic(token.fontStyle) ? 'italic' : undefined,
        fontWeight: isBold(token.fontStyle) ? 'bold' : undefined,
        textDecoration: isUnderline(token.fontStyle) ? 'underline' : undefined,
        ...token.htmlStyle
      } as CSSProperties
    }>
    {token.content}
  </span>
)

// Line numbers are drawn entirely in CSS: a `line` counter incremented per row and rendered via a
// `::before`. This keeps the numbers out of the DOM text, so selecting/copying the code does not also
// copy the line numbers.
const LINE_NUMBER_CLASSES = cn(
  'block',
  'before:content-[counter(line)]',
  'before:inline-block',
  'before:[counter-increment:line]',
  'before:w-8',
  'before:mr-4',
  'before:text-right',
  'before:text-muted-foreground/50',
  'before:font-mono',
  'before:select-none'
)

// Renders one source line. An empty line carries no tokens, so a literal newline is emitted to give the
// row height and to keep the CSS line counter advancing for blank lines.
const LineSpan = ({ keyedLine, showLineNumbers }: { keyedLine: KeyedLine; showLineNumbers: boolean }) => (
  <span className={showLineNumbers ? LINE_NUMBER_CLASSES : 'block'}>
    {keyedLine.tokens.length === 0
      ? '\n'
      : keyedLine.tokens.map(({ token, key }) => <TokenSpan key={key} token={token} />)}
  </span>
)

// Types
type CodeBlockProps = HTMLAttributes<HTMLDivElement> & {
  code: string
  language: BundledLanguage
  showLineNumbers?: boolean
}

interface TokenizedCode {
  tokens: ThemedToken[][]
  fg: string
  bg: string
}

interface CodeBlockContextType {
  code: string
}

// Context
const CodeBlockContext = createContext<CodeBlockContextType>({
  code: ''
})

// All three caches are module-level (not per-component) on purpose: many code blocks render the same
// snippets and languages across the app, and Shiki highlighters are expensive to create. Sharing them
// process-wide means a given language is loaded once and a given snippet is tokenized once.

// One in-flight/loaded highlighter promise per language. Keyed by language so the WASM + grammar load
// happens a single time even if several blocks of that language mount together.
const highlighterCache = new Map<string, Promise<HighlighterGeneric<BundledLanguage, BundledTheme>>>()

// Finished tokenization keyed by (language + content fingerprint); lets later renders of the same code
// return synchronously with no flash.
const tokensCache = new Map<string, TokenizedCode>()

// Components waiting on an async tokenization that is still running. When the highlight finishes, every
// subscriber for that key is notified, so concurrent blocks of the same snippet share one highlight pass.
const subscribers = new Map<string, Set<(result: TokenizedCode) => void>>()

// Fingerprints the snippet without hashing the whole thing: length plus the first and last 100 chars.
// Cheap to compute and collision-safe enough for cache identity here (a real collision would only reuse
// highlighting for two snippets that share length and both ends, which is vanishingly unlikely).
const getTokensCacheKey = (code: string, language: BundledLanguage) => {
  const start = code.slice(0, 100)
  const end = code.length > 100 ? code.slice(-100) : ''
  return `${language}:${code.length}:${start}:${end}`
}

// Returns the shared highlighter promise for a language, creating it on first request. The promise (not
// the resolved highlighter) is cached so simultaneous callers all await the same single load.
const getHighlighter = (language: BundledLanguage): Promise<HighlighterGeneric<BundledLanguage, BundledTheme>> => {
  const cached = highlighterCache.get(language)
  if (cached) {
    return cached
  }

  const highlighterPromise = createHighlighter({
    langs: [language],
    themes: ['github-light', 'github-dark']
  })

  highlighterCache.set(language, highlighterPromise)
  return highlighterPromise
}

// Builds plain (uncolored) tokens straight from the text so the code shows instantly on first paint.
// These are swapped for real Shiki tokens once the async highlight resolves, avoiding a blank gap while
// the highlighter loads.
const createRawTokens = (code: string): TokenizedCode => ({
  bg: 'transparent',
  fg: 'inherit',
  tokens: code.split('\n').map(line =>
    line === ''
      ? []
      : [
          {
            color: 'inherit',
            content: line
          } as ThemedToken
        ]
  )
})

/**
 * Highlights a snippet with a deliberately hybrid sync/async contract:
 * - If the result is already cached, it is returned immediately (synchronous fast path).
 * - Otherwise `null` is returned now, the highlight is kicked off in the background, and the optional
 *   `callback` is invoked with the tokens once they are ready.
 *
 * This shape lets the React component render cached snippets with no effect/setState round-trip while
 * still updating uncached ones when highlighting finishes. The callback is intentionally used instead of
 * returning a promise so the synchronous cache hit and the async path share one call site.
 */
export const highlightCode = (
  code: string,
  language: BundledLanguage,
  // oxlint-disable-next-line eslint-plugin-promise(prefer-await-to-callbacks)
  callback?: (result: TokenizedCode) => void
): TokenizedCode | null => {
  const tokensCacheKey = getTokensCacheKey(code, language)

  // Fast path: already tokenized, hand it back synchronously.
  const cached = tokensCache.get(tokensCacheKey)
  if (cached) {
    return cached
  }

  // Register this caller's callback against the key so it is notified when the in-flight (or about to
  // start) highlight for the same snippet resolves. Multiple callers coalesce onto one highlight pass.
  if (callback) {
    if (!subscribers.has(tokensCacheKey)) {
      subscribers.set(tokensCacheKey, new Set())
    }
    subscribers.get(tokensCacheKey)?.add(callback)
  }

  // Fire-and-forget: the async highlight runs detached and reports back through subscribers, not through
  // this call's return value (which is `null` here, signalling "not ready yet").
  getHighlighter(language)
    // oxlint-disable-next-line eslint-plugin-promise(prefer-await-to-then)
    .then(highlighter => {
      // Guard against a language that failed to load (or an alias the grammar set does not expose): fall
      // back to plain `text` so highlighting degrades to uncolored rather than throwing.
      const availableLangs = highlighter.getLoadedLanguages()
      const langToUse = availableLangs.includes(language) ? language : 'text'

      const result = highlighter.codeToTokens(code, {
        lang: langToUse,
        themes: {
          dark: 'github-dark',
          light: 'github-light'
        }
      })

      const tokenized: TokenizedCode = {
        bg: result.bg ?? 'transparent',
        fg: result.fg ?? 'inherit',
        tokens: result.tokens
      }

      // Store for the next render, then flush and clear the waiting callbacks for this key in one pass.
      tokensCache.set(tokensCacheKey, tokenized)

      const subs = subscribers.get(tokensCacheKey)
      if (subs) {
        for (const sub of subs) {
          sub(tokenized)
        }
        subscribers.delete(tokensCacheKey)
      }
    })
    // oxlint-disable-next-line eslint-plugin-promise(prefer-await-to-then), eslint-plugin-promise(prefer-await-to-callbacks)
    .catch(error => {
      // On failure, drop the subscriber set so callers fall back to the raw tokens they already rendered;
      // nothing is cached, so a later mount may retry the highlight.
      console.error('Failed to highlight code:', error)
      subscribers.delete(tokensCacheKey)
    })

  return null
}

// Renders the highlighted <pre>/<code>. Memoized with an explicit comparator (see below) because
// tokenizing produces a fresh object only when the code actually changes; comparing by reference avoids
// re-rendering every keystroke when a parent re-renders but the tokens are identical.
const CodeBlockBody = memo(
  ({
    tokenized,
    showLineNumbers,
    className
  }: {
    tokenized: TokenizedCode
    showLineNumbers: boolean
    className?: string
  }) => {
    const preStyle = useMemo(
      () => ({
        backgroundColor: tokenized.bg,
        color: tokenized.fg
      }),
      [tokenized.bg, tokenized.fg]
    )

    const keyedLines = useMemo(() => addKeysToTokens(tokenized.tokens), [tokenized.tokens])

    return (
      <pre
        className={cn('dark:!bg-[var(--shiki-dark-bg)] dark:!text-[var(--shiki-dark)] m-0 p-4 text-sm', className)}
        style={preStyle}>
        <code className={cn('font-mono text-sm', showLineNumbers && '[counter-increment:line_0] [counter-reset:line]')}>
          {keyedLines.map(keyedLine => (
            <LineSpan key={keyedLine.key} keyedLine={keyedLine} showLineNumbers={showLineNumbers} />
          ))}
        </code>
      </pre>
    )
  },
  (prevProps, nextProps) =>
    prevProps.tokenized === nextProps.tokenized &&
    prevProps.showLineNumbers === nextProps.showLineNumbers &&
    prevProps.className === nextProps.className
)

CodeBlockBody.displayName = 'CodeBlockBody'

/** Outer frame of a code block (border, background, language data attribute). Hosts the optional header
 * via children and the highlighted content. */
export const CodeBlockContainer = ({
  className,
  language,
  style,
  ...props
}: HTMLAttributes<HTMLDivElement> & { language: string }) => (
  <div
    className={cn('group relative w-full overflow-hidden rounded-md border bg-background text-foreground', className)}
    data-language={language}
    // `content-visibility: auto` lets the browser skip layout/paint for off-screen blocks; the
    // intrinsic-size hint reserves ~200px so scrollbars and scroll position stay stable before a block
    // is rendered. Matters in long transcripts full of code blocks.
    style={{
      containIntrinsicSize: 'auto 200px',
      contentVisibility: 'auto',
      ...style
    }}
    {...props}
  />
)

/** Optional top bar of a code block, e.g. filename on the left and copy/language controls on the right. */
export const CodeBlockHeader = ({ children, className, ...props }: HTMLAttributes<HTMLDivElement>) => (
  <div
    className={cn(
      'flex items-center justify-between border-b bg-muted/80 px-3 py-2 text-muted-foreground text-xs',
      className
    )}
    {...props}>
    {children}
  </div>
)

/** Left side of the header that groups the title/filename. */
export const CodeBlockTitle = ({ children, className, ...props }: HTMLAttributes<HTMLDivElement>) => (
  <div className={cn('flex items-center gap-2', className)} {...props}>
    {children}
  </div>
)

/** Monospace filename label for the header. */
export const CodeBlockFilename = ({ children, className, ...props }: HTMLAttributes<HTMLSpanElement>) => (
  <span className={cn('font-mono', className)} {...props}>
    {children}
  </span>
)

/** Right side of the header that groups action controls (copy button, language selector). */
export const CodeBlockActions = ({ children, className, ...props }: HTMLAttributes<HTMLDivElement>) => (
  <div className={cn('-my-1 -mr-1 flex items-center gap-2', className)} {...props}>
    {children}
  </div>
)

/**
 * Resolves the best available tokens for a snippet and renders them, upgrading from raw → cached →
 * freshly-highlighted as each becomes available. Built so a cached snippet paints fully highlighted on
 * the first render with no effect-driven flash, while an uncached one starts raw and fills in.
 */
export const CodeBlockContent = ({
  code,
  language,
  showLineNumbers = false
}: {
  code: string
  language: BundledLanguage
  showLineNumbers?: boolean
}) => {
  // Plain tokens, recomputed only when the code changes; the always-available baseline.
  const rawTokens = useMemo(() => createRawTokens(code), [code])

  // Synchronous cache hit (if any) on this very render; falls back to raw. Using the cache here instead
  // of an effect means previously-seen snippets render highlighted immediately, not one frame later.
  const syncTokens = useMemo(() => highlightCode(code, language) ?? rawTokens, [code, language, rawTokens])

  // Highlight that arrives later, once Shiki has loaded for an uncached snippet.
  const [asyncTokens, setAsyncTokens] = useState<TokenizedCode | null>(null)
  const asyncKeyRef = useRef({ code, language })

  // When the code/language changes, the previous async result is stale. Clearing it during render (not in
  // an effect) prevents a flash where the new code is briefly shown with the old snippet's colors.
  if (asyncKeyRef.current.code !== code || asyncKeyRef.current.language !== language) {
    asyncKeyRef.current = { code, language }
    setAsyncTokens(null)
  }

  useEffect(() => {
    // `cancelled` drops a late callback that resolves after the code/language changed or the block
    // unmounted, so we never setState with tokens for a snippet we no longer show.
    let cancelled = false

    highlightCode(code, language, result => {
      if (!cancelled) {
        setAsyncTokens(result)
      }
    })

    return () => {
      cancelled = true
    }
  }, [code, language])

  // Prefer the freshly highlighted tokens; otherwise the synchronous (cached or raw) ones.
  const tokenized = asyncTokens ?? syncTokens

  return (
    <div className="relative overflow-auto">
      <CodeBlockBody showLineNumbers={showLineNumbers} tokenized={tokenized} />
    </div>
  )
}

/** Top-level code block: frame + highlighted content, with the raw `code` exposed through context so a
 * nested copy button can read it without prop drilling. `children` slot in the optional header. */
export const CodeBlock = ({
  code,
  language,
  showLineNumbers = false,
  className,
  children,
  ...props
}: CodeBlockProps) => {
  const contextValue = useMemo(() => ({ code }), [code])

  return (
    <CodeBlockContext.Provider value={contextValue}>
      <CodeBlockContainer className={className} language={language} {...props}>
        {children}
        <CodeBlockContent code={code} language={language} showLineNumbers={showLineNumbers} />
      </CodeBlockContainer>
    </CodeBlockContext.Provider>
  )
}

export type CodeBlockCopyButtonProps = ComponentProps<typeof Button> & {
  onCopy?: () => void
  onError?: (error: Error) => void
  timeout?: number
}

/** Copy-to-clipboard button for the enclosing code block; reads the code from context and briefly shows a
 * check icon after a successful copy. */
export const CodeBlockCopyButton = ({
  onCopy,
  onError,
  timeout = 2000,
  children,
  className,
  ...props
}: CodeBlockCopyButtonProps) => {
  const [isCopied, setIsCopied] = useState(false)
  const timeoutRef = useRef<number>(0)
  const { code } = useContext(CodeBlockContext)

  const copyToClipboard = useCallback(async () => {
    // Bail out (and report) when there is no Clipboard API: SSR, or a non-secure context where
    // `navigator.clipboard` is unavailable.
    if (typeof window === 'undefined' || !navigator?.clipboard?.writeText) {
      onError?.(new Error('Clipboard API not available'))
      return
    }

    try {
      // Ignore repeat clicks while the "copied" state is still showing, so the reset timer is not stacked.
      if (!isCopied) {
        await navigator.clipboard.writeText(code)
        setIsCopied(true)
        onCopy?.()
        // Flip the icon back to "copy" after the timeout.
        timeoutRef.current = window.setTimeout(() => setIsCopied(false), timeout)
      }
    } catch (error) {
      onError?.(error as Error)
    }
  }, [code, onCopy, onError, timeout, isCopied])

  // Clear a pending reset timer on unmount so it cannot fire setState on a gone component.
  useEffect(
    () => () => {
      window.clearTimeout(timeoutRef.current)
    },
    []
  )

  const Icon = isCopied ? CheckIcon : CopyIcon

  return (
    <Button className={cn('shrink-0', className)} onClick={copyToClipboard} size="icon" variant="ghost" {...props}>
      {children ?? <Icon size={14} />}
    </Button>
  )
}

export type CodeBlockLanguageSelectorProps = ComponentProps<typeof Select>

/** Dropdown for switching the highlighting language of a code block. The pieces below are thin
 * presentational wrappers over the shared Select primitives. */
export const CodeBlockLanguageSelector = (props: CodeBlockLanguageSelectorProps) => <Select {...props} />

export type CodeBlockLanguageSelectorTriggerProps = ComponentProps<typeof SelectTrigger>

export const CodeBlockLanguageSelectorTrigger = ({ className, ...props }: CodeBlockLanguageSelectorTriggerProps) => (
  <SelectTrigger
    className={cn('h-7 border-none bg-transparent px-2 text-xs shadow-none', className)}
    size="sm"
    {...props}
  />
)

export type CodeBlockLanguageSelectorValueProps = ComponentProps<typeof SelectValue>

export const CodeBlockLanguageSelectorValue = (props: CodeBlockLanguageSelectorValueProps) => <SelectValue {...props} />

export type CodeBlockLanguageSelectorContentProps = ComponentProps<typeof SelectContent>

export const CodeBlockLanguageSelectorContent = ({
  align = 'end',
  ...props
}: CodeBlockLanguageSelectorContentProps) => <SelectContent align={align} {...props} />

export type CodeBlockLanguageSelectorItemProps = ComponentProps<typeof SelectItem>

export const CodeBlockLanguageSelectorItem = (props: CodeBlockLanguageSelectorItemProps) => <SelectItem {...props} />
