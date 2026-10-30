import { lazy, Suspense } from 'react'
import { cn } from '@ankole/uikit'
import { ErrorBoundary } from '../../common/error-boundary'

const MarkdownRenderer = lazy(() => import('./markdown-renderer'))

export function ChatMarkdown({ text, className }: { text: string; className?: string }) {
  const plain = <div className="whitespace-pre-wrap break-words">{text}</div>
  return (
    <div className={cn('pod-chat-markdown', className)}>
      <ErrorBoundary resetKeys={[text]} fallback={plain}>
        <Suspense fallback={plain}>
          <MarkdownRenderer text={text} />
        </Suspense>
      </ErrorBoundary>
    </div>
  )
}
