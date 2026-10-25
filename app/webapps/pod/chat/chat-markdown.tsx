import { lazy, Suspense } from 'react'
import { cn } from '@ankole/uikit'

const MarkdownRenderer = lazy(() => import('./markdown-renderer'))

export function ChatMarkdown({ text, className }: { text: string; className?: string }) {
  return (
    <div className={cn('pod-chat-markdown', className)}>
      <Suspense fallback={<div className="whitespace-pre-wrap break-words">{text}</div>}>
        <MarkdownRenderer text={text} />
      </Suspense>
    </div>
  )
}
