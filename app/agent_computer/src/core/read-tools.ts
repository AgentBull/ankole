import { isRecord } from '@agentbull/active-support'
import type { JsonObject } from '@agentbull/active-support'
import { jsonBytes, jsonObjectFromBytes } from '../fabric/envelope_proto'
import type { JobTurnRef } from '../lanes/actor_lane'
import type { RPCRequester } from '../lanes/rpc_lane'
import type { AgentToolResult } from './types'

/** Codec adapter only; the control plane owns read-tool behavior and results. */
export async function readTool(
  rpc: RPCRequester,
  turn: JobTurnRef,
  name: string,
  args: JsonObject,
  opts: {
    cache?: JsonObject
    renderedFetch?: (urls: string[], signal?: AbortSignal) => Promise<JsonObject>
    signal?: AbortSignal
  } = {}
): Promise<AgentToolResult<JsonObject>> {
  const invoke = async (rendered?: JsonObject) => {
    const response = await rpc(
      'tools.read',
      {
        name,
        argumentsJson: jsonBytes(args),
        ...(opts.cache ? { webCacheJson: jsonBytes(opts.cache) } : {}),
        ...(rendered ? { renderedBodyJson: jsonBytes(rendered) } : {})
      },
      { jobTurn: turn },
      { signal: opts.signal, retryOnDisconnect: true, timeoutMs: 180_000 }
    )
    const body = jsonObjectFromBytes(response.bodyJson, 'tools.read response')
    if (!body) throw new Error('empty read tool response')
    return body
  }
  let body = await invoke()
  if (isRecord(body.delegate)) {
    if (body.delegate.name !== '__rendered_web_fetch' || !opts.renderedFetch) {
      throw new Error('The web page provider and rendered fallback are unavailable.')
    }
    const urls = (body.delegate.arguments as { urls: string[] }).urls
    body = await invoke(await opts.renderedFetch(urls, opts.signal))
  }
  if (opts.cache && isRecord(body.web_cache)) {
    Object.assign(opts.cache, body.web_cache)
    const entries = Object.entries(opts.cache).sort(
      (a, b) => Number((b[1] as { at: number }).at) - Number((a[1] as { at: number }).at)
    )
    for (const [url] of entries.slice(100)) delete opts.cache[url]
  }
  return {
    content: [{ type: 'text', text: typeof body.output === 'string' ? body.output : '' }],
    details: isRecord(body.details) ? body.details : {},
    ...(body.is_error === true ? { isError: true } : {})
  }
}
