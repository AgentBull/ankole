import { useMemo } from 'react'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { mountSpa } from '../mount-spa'
import { ReasoningTracePanel, useReasoningTraceOutput, type ReasoningTraceFetcher } from './trace-view'

function ReasoningTraceApp() {
  const token = decodeURIComponent(window.location.pathname.split('/').filter(Boolean).at(-1) ?? '')
  const fetchEvents = useMemo<ReasoningTraceFetcher | undefined>(() => {
    if (!token) return undefined
    return async after => {
      const url = new URL(`/api/public/reasoning-traces/${encodeURIComponent(token)}/events`, window.location.origin)
      if (after) url.searchParams.set('after', after)
      const response = await fetch(url, { cache: 'no-store' })
      const body = (await response.json().catch(() => ({}))) as { error?: string }
      if (!response.ok) throw new Error(body.error ?? `Request failed: ${response.status}`)
      return body as Awaited<ReturnType<ReasoningTraceFetcher>>
    }
  }, [token])
  const snapshot = useReasoningTraceOutput(fetchEvents, token)

  return (
    <main className="min-h-screen bg-background px-4 py-6 text-foreground">
      <div className="mx-auto flex w-full max-w-4xl flex-col gap-4">
        <Card>
          <CardHeader>
            <CardTitle>推理过程</CardTitle>
          </CardHeader>
          <CardContent>
            <ReasoningTracePanel snapshot={snapshot} />
          </CardContent>
        </Card>
      </div>
    </main>
  )
}

mountSpa(<ReasoningTraceApp />)
