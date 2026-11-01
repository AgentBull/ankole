import { lazy, Suspense } from 'react'
import { cn } from '@ankole/uikit'
import { ErrorBoundary } from '../../common/error-boundary'

const MarkdownRenderer = lazy(() => import('./markdown-renderer'))

export function ChatMarkdown({
  text,
  generated = false,
  streaming = false,
  className
}: {
  text: string
  generated?: boolean
  streaming?: boolean
  className?: string
}) {
  const plain = <div className="whitespace-pre-wrap break-words">{text}</div>
  return (
    <div className={cn('pod-chat-markdown', className)}>
      <ErrorBoundary resetKeys={[text, generated, streaming]} fallback={plain}>
        <Suspense fallback={plain}>
          <MarkdownRenderer text={text} generated={generated} streaming={streaming} />
        </Suspense>
      </ErrorBoundary>
    </div>
  )
}
