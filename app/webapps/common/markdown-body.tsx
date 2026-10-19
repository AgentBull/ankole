import { cn } from '@ankole/uikit'
import { lazy, Suspense } from 'react'

const MarkdownRenderer = lazy(() => import('./markdown-renderer'))

/**
 * Read-only Markdown renderer for recorded conversation content (user and
 * assistant text). The parser stack loads on demand; until it lands the text
 * shows as plain pre-wrapped prose, so content is readable immediately.
 */
export function MarkdownBody({ text, className, copyCode }: { text: string; className?: string; copyCode?: boolean }) {
  return (
    <div className={cn('text-sm leading-6 break-words text-foreground', className)}>
      <Suspense fallback={<p className="whitespace-pre-wrap">{text}</p>}>
        <MarkdownRenderer text={text} copyCode={copyCode} />
      </Suspense>
    </div>
  )
}
