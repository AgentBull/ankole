import { QueryClient } from '@tanstack/react-query'
import { createReadDenials } from '@ankole/applet-sdk'
import type {
  ActionRun,
  AppletBindings,
  AppletRevision,
  AppletRuntime,
  PodFileTarget,
  RoutesAPI,
  RouteCall
} from '@ankole/applet-sdk/types'
import { mountApplet, readDocumentTheme, subjectsToPodPrincipals, type PodSubjectItem } from '../pod/applet-host'

const config = JSON.parse(document.getElementById('applet-diagnostic-config')!.textContent!) as {
  page: { id: string; title: string }
  revision: AppletRevision
  bindings: AppletBindings
  bindings_digest: string
  principal: { uid: string }
  prefix: string
}

function readFragmentProps(): Record<string, unknown> {
  const match = /^#props=([A-Za-z0-9_-]+)$/.exec(window.location.hash)
  if (!match) return {}
  try {
    const padded = match[1]!.replace(/-/g, '+').replace(/_/g, '/')
    const binary = atob(padded + '='.repeat((4 - (padded.length % 4)) % 4))
    const bytes = Uint8Array.from(binary, char => char.charCodeAt(0))
    const parsed: unknown = JSON.parse(new TextDecoder().decode(bytes))
    return parsed && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

const embedProps = readFragmentProps()
const diagnostic = { mounted: false, settled: false, runtimeErrors: [] as string[] }
Object.assign(window, { __ANKOLE_APPLET_DIAGNOSTIC__: diagnostic })
const fail = (error: unknown) => {
  diagnostic.settled = true
  diagnostic.runtimeErrors.push(error instanceof Error ? error.message : String(error))
}
window.addEventListener('error', event => fail(event.error ?? event.message))
window.addEventListener('unhandledrejection', event => fail(event.reason))
const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
const denials = createReadDenials(client.getQueryCache())
async function request<T>(path: string, method = 'GET', body?: unknown, signal?: AbortSignal): Promise<T> {
  const response = await fetch(`${config.prefix}/api${path}`, {
    method,
    signal,
    credentials: 'omit',
    headers: {
      accept: 'application/vnd.api+json',
      ...(body === undefined ? {} : { 'content-type': 'application/vnd.api+json' })
    },
    body: body === undefined ? undefined : JSON.stringify({ data: body })
  })
  const payload = response.status === 204 ? undefined : await response.json()
  if (!response.ok) throw Object.assign(new Error(JSON.stringify(payload)), { status: response.status, payload })
  return payload as T
}
const routes: RoutesAPI = {
  key: () => ['applet-diagnostic-routes', config.page.id, config.revision, config.bindings_digest],
  async call<T>({ method, path, query, body, signal }: RouteCall) {
    const search = new URLSearchParams()
    for (const [key, value] of Object.entries(query ?? {})) {
      for (const item of Array.isArray(value) ? value : [value]) search.append(key, item)
    }
    const response = await fetch(
      `${config.prefix}/api/pages/${config.page.id}/routes${path}${search.size ? `?${search}` : ''}`,
      {
        method,
        signal,
        credentials: 'omit',
        headers: { 'content-type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body)
      }
    )
    const payload = response.status === 204 ? undefined : await response.json()
    if (!response.ok) throw Object.assign(new Error(JSON.stringify(payload)), { status: response.status, payload })
    return payload as T
  }
}
function fileURL(target: PodFileTarget) {
  const path = typeof target === 'string' ? target : target.path
  const page = typeof target === 'string' ? config.page.id : (target.pageID ?? target.pageId ?? config.page.id)
  const search = new URLSearchParams({ path })
  if (typeof target !== 'string' && target.sha256) search.set('sha256', target.sha256)
  return `${config.prefix}/api/pages/${encodeURIComponent(page)}/files/content?${search}`
}
const runtime: Omit<AppletRuntime, 'revision' | 'routes' | 'embedded'> = {
  pageID: config.page.id,
  title: config.page.title,
  instanceID: 'diagnostic',
  actions: ['node_view'],
  bindings: config.bindings,
  bindingsDigest: config.bindings_digest,
  embedProps,
  queryClient: client,
  readDenial: denials.get,
  principal: config.principal,
  get theme() {
    return readDocumentTheme()
  },
  base: {
    key: id => ['applet-diagnostic-table', id],
    schema: id => request(`/tables/${id}`),
    records: (id, query) => {
      const { group, groups, ...rest } = query
      const body = Array.isArray(group)
        ? { ...rest, groups: [...(groups ?? []), ...group] }
        : { ...rest, ...(group ? { group } : {}), ...(groups ? { groups } : {}) }
      return request(`/tables/${id}/query`, 'POST', body)
    },
    aggregate: (id, query) => request(`/tables/${id}/aggregate`, 'POST', query),
    write: (id, changes) => request(`/tables/${id}/records`, 'POST', changes),
    subscribe: () => () => {}
  },
  pod: {
    request,
    fileURL,
    navigateToPage() {},
    openChat() {},
    principals: async () => {
      const result = await request<{ subjects: PodSubjectItem[] }>('/subjects')
      return subjectsToPodPrincipals(result.subjects)
    }
  },
  runs: {
    key: id => ['applet-diagnostic-run', id],
    get: (id, signal) =>
      request<{ run: ActionRun }>(
        `/pages/${encodeURIComponent(config.page.id)}/runs/${encodeURIComponent(id)}`,
        'GET',
        undefined,
        signal
      ).then(body => body.run),
    subscribe: () => () => {}
  },
  channel: () => ({
    presence: () => [],
    subscribe: () => () => {},
    on: () => () => {},
    close() {},
    broadcast: async () => {
      await request('/channels', 'POST', {})
    }
  })
}
const mounted = mountApplet(
  config.page.id,
  config.revision,
  document.getElementById('applet-diagnostic')!,
  runtime,
  fail,
  () => {
    diagnostic.mounted = true
    diagnostic.settled = true
  },
  () => fail('applet_revision_changed'),
  { frameURL: `${config.prefix}/frame/index.html`, principal: config.principal.uid, routes }
)
window.addEventListener(
  'pagehide',
  () => {
    mounted.dispose()
    denials.dispose()
    client.clear()
  },
  { once: true }
)
