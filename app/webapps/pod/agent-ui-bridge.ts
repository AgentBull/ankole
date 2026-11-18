import { createAgent, registerTools, type AgentAction } from '@ankole/uikit/lib/agent'
import { isRealtimeAccessDenied, type PodRealtime, type TopicHandle } from './realtime'

/** A request the control plane relays from an Ankole Agent's `pod_ui_*` tool to the tabs of the person it works for. */
export type AgentUIRequest = {
  id: string
  operation: 'snapshot' | 'act' | 'query'
  arguments: Record<string, unknown>
  agent: { uid: string; name: string }
}

type Bridge = Pick<ReturnType<typeof createAgent>, 'snapshot' | 'act' | 'query'>

/** Asks the person whether a marked step may run. `agentName` is undefined for the browser's own assistant. */
type AgentUIConfirm = (agentName: string | undefined, step: AgentAction, signal: AbortSignal) => Promise<boolean>

/** A hidden tab waits this long before it claims, so the tab the person is looking at wins. */
export const HIDDEN_TAB_CLAIM_DELAY = 2000

async function execute(bridge: Bridge, request: AgentUIRequest) {
  switch (request.operation) {
    case 'snapshot':
      return bridge.snapshot()
    case 'act':
      return bridge.act(request.arguments as Parameters<Bridge['act']>[0])
    case 'query':
      return bridge.query(request.arguments)
    default:
      throw new Error(`Unknown agent UI operation: ${String(request.operation)}`)
  }
}

/**
 * Claims and runs the `agent_ui` requests that reach this tab, one at a time, and pushes each outcome back. The
 * control plane accepts only the first claim, so only one of the person's tabs runs a request. `running` hears the
 * request that is running, then `undefined` when it finishes.
 */
export function serveAgentUIRequests(
  channel: Pick<TopicHandle, 'push' | 'on'>,
  bridge: Bridge,
  running: (request?: AgentUIRequest) => void
): () => void {
  const seen = new Set<string>()
  const timers = new Set<ReturnType<typeof setTimeout>>()
  let queue = Promise.resolve()
  let stopped = false

  const run = async (request: AgentUIRequest) => {
    if (stopped) return
    let reply: { id: string; result: unknown } | { id: string; error: string }
    running(request)
    try {
      reply = { id: request.id, result: await execute(bridge, request) }
    } catch (error) {
      reply = { id: request.id, error: error instanceof Error ? error.message : String(error) }
    } finally {
      running(undefined)
    }
    await channel.push('result', reply).catch(() => {})
  }
  const claim = (request: AgentUIRequest) => {
    if (stopped) return
    // A rejected claim means another tab took the request or it expired; either way this tab leaves it.
    channel.push('claim', { id: request.id }).then(
      () => {
        queue = queue.then(() => run(request))
      },
      () => {}
    )
  }
  const off = channel.on('request', (request: AgentUIRequest) => {
    // The control plane pushes unclaimed requests again after every join, so a request may arrive twice.
    if (seen.has(request.id)) return
    seen.add(request.id)
    if (document.visibilityState === 'visible') return claim(request)
    const timer = setTimeout(() => {
      timers.delete(timer)
      claim(request)
    }, HIDDEN_TAB_CLAIM_DELAY)
    timers.add(timer)
  })
  return () => {
    stopped = true
    off()
    for (const timer of timers) clearTimeout(timer)
  }
}

// ui-sdk's bridge has no teardown, so the tab keeps one bridge for its whole life and reconnects only its callers.
let bridge: ReturnType<typeof createAgent> | undefined
let decide: (step: AgentAction, signal: AbortSignal) => boolean | Promise<boolean> = step => !step.confirm

/**
 * Lets Ankole Agents operate this tab through the `agent_ui` channel, and the browser's own assistant through
 * WebMCP where the browser has it. Ordinary steps run at once; a step on a control marked `data-agent-confirm`
 * waits for `confirm`. Returns the function that disconnects both.
 */
export function connectAgentUI(realtime: PodRealtime, confirm: AgentUIConfirm): () => void {
  let current: AgentUIRequest | undefined
  // shortcut: a WebMCP call that runs while an Agent request waits in the bridge's queue asks in that Agent's name;
  // tell the callers apart inside the bridge if both ever operate one tab at the same time.
  decide = (step, signal) => !step.confirm || !current || confirm(current.agent.name, step, signal)
  bridge ??= createAgent({ allow: (step, { signal }) => decide(step, signal) })
  // The browser's assistant has no channel request, so `decide` lets its steps through to this check.
  const unregister = registerTools(bridge, {
    allow: (step, { signal }) => !step.confirm || confirm(undefined, step, signal)
  })
  let closed = false
  let retry: ReturnType<typeof setTimeout> | undefined
  let disconnect = () => {}
  const subscribe = () => {
    realtime.join('agent_ui').then(
      handle => {
        if (closed) return handle.close()
        const stop = serveAgentUIRequests(handle, bridge!, request => {
          current = request
        })
        disconnect = () => {
          stop()
          handle.close()
        }
      },
      error => {
        if (!closed && !isRealtimeAccessDenied(error)) retry = setTimeout(subscribe, 1000)
      }
    )
  }
  subscribe()
  return () => {
    closed = true
    clearTimeout(retry)
    disconnect()
    unregister()
    decide = step => !step.confirm
  }
}
