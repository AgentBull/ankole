import { lazy, Suspense } from 'react'
import { cn } from '@ankole/uikit'
import { ErrorBoundary } from '../../common/error-boundary'

const MarkdownRenderer = lazy(() => import('./markdown-renderer'))

export function ChatMarkdown({
  text,
  generated = false,
  streaming = false,
  className,
  onReply
}: {
  text: string
  generated?: boolean
  streaming?: boolean
  className?: string
  /** Receives the follow-up text of a `ui` block's reply button; without it the button does nothing. */
  onReply?: (text: string) => void
}) {
  const plain = <div className="whitespace-pre-wrap break-words">{text}</div>
  return (
    <div
      className={cn('pod-chat-markdown', streaming && 'pod-chat-live-text', className)}
      aria-busy={streaming || undefined}>
      <ErrorBoundary resetKeys={[text, generated, streaming]} fallback={plain}>
        <Suspense fallback={plain}>
          <MarkdownRenderer
            text={text}
            generated={generated}
            streaming={streaming}
            reveal={generated && streaming}
            onReply={onReply}
          />
        </Suspense>
      </ErrorBoundary>
    </div>
  )
}
