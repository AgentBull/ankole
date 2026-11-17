import { t } from 'i18next'
import {
  Component,
  createContext,
  useContext,
  useCallback,
  useSyncExternalStore,
  useEffect,
  useRef,
  useMemo,
  useState,
  type ComponentType,
  type ReactNode
} from 'react'
import { createRoot, type Root } from 'react-dom/client'
import {
  hashKey,
  QueryClientProvider,
  useMutation,
  useMutationState,
  useQuery,
  useQueryClient,
  type UseQueryOptions,
  type UseQueryResult,
  type QueryCache,
  type QueryKey,
  type UseMutationOptions
} from '@tanstack/react-query'
import { followAggregateTables } from './aggregate-tables'
import { previewRecordList } from './records'
import { boundTable } from './bindings'
export { expectedVersions } from './records'
import type {
  AggregateQuery,
  AppletRuntime,
  EphemeralChannel,
  PodPrincipal,
  PresenceMember,
  RecordData,
  RecordQuery,
  RecordWrite,
  Route,
  GetRoute,
  MutationRoute,
  RouteMethod,
  RouteParams,
  RouteQuery,
  RouteVariables,
  Versions
} from './types'
export type * from './types'
export * from './job-sources'
export * from './jobs'
export * from './viz'
import { createJobSources } from './job-sources'
import { createAppletJobs } from './jobs'

const Runtime = createContext<AppletRuntime | null>(null)
export function AppletRuntimeProvider({ runtime, children }: { runtime: AppletRuntime; children: ReactNode }) {
  return <Runtime value={runtime}>{children}</Runtime>
}
export function usePod() {
  const runtime = useContext(Runtime)
  if (!runtime) throw new Error('This component must run inside an Ankole applet')
  return runtime
}

/** Manage a persistent Action's native schedules and webhook endpoints. */
export function useJobSources(jobID: number) {
  const { pod, pageID } = usePod()
  return useMemo(() => createJobSources(pod, pageID, jobID), [pod, pageID, jobID])
}

export function useAppletJobs() {
  const { pod, pageID } = usePod()
  return useMemo(() => createAppletJobs(pod, pageID), [pod, pageID])
}

export type PrincipalReference = string | { uid?: string | null } | null | undefined

/** Extracts a normalized Principal UID from bare UIDs, ActorRef strings/maps, or Brain Principal slugs. */
export function normalizePrincipalUID(value: PrincipalReference): string | null {
  if (value === null || value === undefined) return null
  const raw = typeof value === 'string' ? value : typeof value.uid === 'string' ? value.uid : ''
  const trimmed = raw.trim()
  if (!trimmed) return null
  const afterPrincipal = trimmed.includes(':principal/')
    ? trimmed.slice(trimmed.indexOf(':principal/') + ':principal/'.length)
    : /^(?:people|agents)\/[^/]+$/i.test(trimmed)
      ? trimmed.slice(trimmed.indexOf('/') + 1)
      : trimmed.replace(/^@/, '')
  const normalized = afterPrincipal.trim().toLowerCase()
  return normalized || null
}

/** Reads visible human and AI Colleague Principals in the Pod, optionally narrowed to a UID list. */
export function usePrincipals(uids?: readonly PrincipalReference[]) {
  const runtime = usePod()
  const queryKey = runtime.pod.principalsKey ?? (['pod', 'principals'] as const)
  const read = useQuery({
    queryKey,
    queryFn: () => runtime.pod.principals(),
    staleTime: 60_000
  })
  const result = useReadResult(read, queryKey)
  const byUid = useMemo(() => {
    const map = new Map<string, PodPrincipal>()
    for (const item of result.data ?? []) {
      const normalized = normalizePrincipalUID(item.uid)
      if (normalized) map.set(normalized, item)
    }
    return map as ReadonlyMap<string, PodPrincipal>
  }, [result.data])
  const principals = useMemo(() => {
    if (!uids) return result.data ?? []
    const seen = new Set<string>()
    const resolved: PodPrincipal[] = []
    for (const ref of uids) {
      const normalized = normalizePrincipalUID(ref)
      if (!normalized || seen.has(normalized)) continue
      seen.add(normalized)
      const match = byUid.get(normalized)
      if (match) resolved.push(match)
    }
    return resolved
  }, [byUid, result.data, uids])
  return {
    ...result,
    principals,
    byUid
  }
}

export function usePrincipal(uid: PrincipalReference) {
  const normalized = normalizePrincipalUID(uid)
  const directory = usePrincipals()
  return {
    ...directory,
    uid: normalized,
    principal: normalized ? directory.byUid.get(normalized) : undefined
  }
}

// A failed authenticated refetch must hide prior rows even if the live channel is temporarily unavailable.
function readDenied(error: unknown): boolean {
  return (
    !!error &&
    typeof error === 'object' &&
    'status' in error &&
    typeof error.status === 'number' &&
    [401, 403, 404].includes(error.status)
  )
}

/** The host keeps read denials across Applet generations and disposes its cache subscription. */
export function createReadDenials(cache: QueryCache) {
  const denials = new WeakMap<object, unknown>()
  for (const query of cache.getAll()) {
    const error = [query.state.error, query.state.fetchFailureReason].find(readDenied)
    if (error) denials.set(query, error)
  }
  const dispose = cache.subscribe(event => {
    if (event.type === 'removed') denials.delete(event.query)
    if (event.type !== 'updated') return
    if (event.action.type === 'success' && !event.action.manual) {
      denials.delete(event.query)
    } else {
      const error = [event.query.state.error, event.query.state.fetchFailureReason].find(readDenied)
      if (error) denials.set(event.query, error)
    }
  })
  return { get: (query: object) => denials.get(query), dispose }
}

function useQueryReadDenial<Error = globalThis.Error>(runtime: AppletRuntime, queryKey: QueryKey) {
  const cache = useQueryClient().getQueryCache()
  const hash = hashKey(queryKey)
  const subscribe = useCallback(
    (notify: () => void) =>
      cache.subscribe(event => {
        if (event.query.queryHash === hash) notify()
      }),
    [cache, hash]
  )
  const snapshot = useCallback(() => {
    const query = cache.get(hash)
    return query ? (runtime.readDenial(query) as Error | undefined) : undefined
  }, [cache, hash, runtime])
  const denial = useSyncExternalStore(subscribe, snapshot, snapshot)
  return useCallback(
    (error: unknown, failureReason: unknown, revokedError?: Error): Error | undefined =>
      revokedError ?? denial ?? ([error, failureReason].find(readDenied) as Error | undefined),
    [denial]
  )
}

export function useTableReadDenial<Error = globalThis.Error>(
  runtime: AppletRuntime,
  tableID: string,
  queryKey: QueryKey,
  enabled = true
) {
  const [revoked, setRevoked] = useState(false)
  useEffect(() => {
    setRevoked(false)
    if (!enabled) return
    return runtime.base.subscribe(tableID, event => {
      if (event.access_revoked) setRevoked(true)
    })
  }, [runtime, tableID, enabled])
  const resolveQueryDenial = useQueryReadDenial<Error>(runtime, queryKey)
  const resolveDenial = useCallback(
    (error: unknown, failureReason: unknown): Error | undefined =>
      resolveQueryDenial(
        error,
        failureReason,
        revoked ? (new Error(t('pod.content.you_no_longer_have_access_to_this_table')) as Error) : undefined
      ),
    [resolveQueryDenial, revoked]
  )
  return { revoked, resolveDenial }
}

function withDeniedError<Data, Error>(
  result: UseQueryResult<Data, Error>,
  error: Error | undefined
): UseQueryResult<Data, Error> {
  if (error == null) return result
  return {
    ...result,
    data: undefined,
    error,
    status: 'error',
    isError: true,
    isSuccess: false,
    isPending: false,
    isLoading: false,
    isInitialLoading: false,
    isLoadingError: true,
    isRefetchError: false,
    isPlaceholderData: false,
    isRefetching: result.isFetching
  }
}

function useReadResult<Data, Error>(
  result: UseQueryResult<Data, Error>,
  queryKey: QueryKey,
  revokedError?: Error
): UseQueryResult<Data, Error> {
  const runtime = usePod()
  const resolveQueryDenial = useQueryReadDenial<Error>(runtime, queryKey)
  return withDeniedError(result, resolveQueryDenial(result.error, result.failureReason, revokedError))
}

export function useRecords(tableID: string, options: RecordQuery & { pageSize?: number; enabled?: boolean } = {}) {
  const { pageSize, enabled = true, ...rest } = options
  const query: RecordQuery = pageSize === undefined ? rest : { ...rest, page_size: pageSize }
  const runtime = usePod()
  const queryKey = [...runtime.base.key(tableID), 'records', query]
  const { revoked, resolveDenial } = useTableReadDenial(runtime, tableID, queryKey, enabled)
  const read = useQuery({
    queryKey,
    queryFn: () => runtime.base.records(tableID, query),
    enabled: enabled && !revoked
  })
  const records = withDeniedError(read, resolveDenial(read.error, read.failureReason))
  const write = useRecordWrites(tableID)
  const pending = useMutationState({
    filters: { mutationKey: [...runtime.base.key(tableID), 'write'], status: 'pending' },
    select: mutation => mutation.state.variables as RecordWrite
  })
  const confirmed = records.data
  const data = useMemo(() => {
    if (!confirmed) return confirmed
    const previewed = previewRecordList(confirmed.records, pending)
    return previewed === confirmed.records ? confirmed : { ...confirmed, records: previewed }
  }, [confirmed, pending])
  return { ...records, data, ...write }
}

export function useAggregate(
  tableID: string,
  options: AggregateQuery & { groupBy?: AggregateQuery['group_by']; enabled?: boolean }
) {
  const { groupBy, enabled = true, ...rest } = options
  const query = groupBy === undefined ? rest : { ...rest, group_by: groupBy }
  const runtime = usePod()
  const queryKey = [...runtime.base.key(tableID), 'aggregate', query]
  const { revoked, resolveDenial } = useTableReadDenial(runtime, tableID, queryKey, enabled)
  const client = useQueryClient()
  const hash = hashKey(queryKey)
  const result = useQuery({
    queryKey,
    queryFn: () => runtime.base.aggregate(tableID, query),
    enabled: enabled && !revoked
  })
  useEffect(
    () => (enabled ? followAggregateTables(runtime.base, client, tableID, queryKey) : undefined),
    [runtime, client, tableID, hash, enabled]
  )
  return withDeniedError(result, resolveDenial(result.error, result.failureReason))
}

/** Substitute each path segment once. A parameter cannot introduce another segment. */
export function resolveRoute(route: Route, params: RouteParams = {}) {
  const separator = route.indexOf(' ')
  const method = route.slice(0, separator) as RouteMethod
  const path = route.slice(separator + 1).replace(/(^|\/):([^/]+)/g, (_match, prefix: string, name: string) => {
    if (!Object.hasOwn(params, name) || !params[name]) throw new Error(`Missing route parameter: ${name}`)
    return prefix + encodeURIComponent(params[name]!)
  })
  return { method, path }
}

export type RouteOptions<Data, Error = globalThis.Error, Selected = Data> = Omit<
  UseQueryOptions<Data, Error, Selected>,
  'queryKey' | 'queryFn'
> & {
  params?: RouteParams
  query?: RouteQuery
}

export function useRoute<Data = unknown, Error = globalThis.Error, Selected = Data>(
  route: GetRoute,
  options: RouteOptions<Data, Error, Selected> = {}
) {
  if (!route.startsWith('GET /')) throw new Error('useRoute requires a GET route')
  const runtime = usePod()
  const { params, query, ...queryOptions } = options
  const queryKey = [...runtime.routes.key(), route, params, query]
  const result = useQuery({
    ...queryOptions,
    queryKey,
    queryFn: ({ signal }) => {
      const { method, path } = resolveRoute(route, params)
      return runtime.routes.call<Data>({ method, path, query, signal })
    }
  })
  return useReadResult(result, queryKey)
}

/** Observe a durable Action, including changes committed while the browser was disconnected. */
export function useActionRun(runID: number | null) {
  const runtime = usePod()
  const [revoked, setRevoked] = useState(false)
  useEffect(() => {
    setRevoked(false)
    if (runID === null) return
    return runtime.runs.subscribe(runID, event => {
      if (event.access_revoked) setRevoked(true)
    })
  }, [runtime, runID])
  const queryKey = runtime.runs.key(runID ?? 0)
  const result = useQuery({
    queryKey,
    queryFn: ({ signal }) => runtime.runs.get(runID!, signal),
    enabled: runID !== null && !revoked
  })
  return useReadResult(
    result,
    queryKey,
    revoked ? new Error(t('pod.content.you_no_longer_have_access_to_this_applet')) : undefined
  )
}

export function useRouteMutation<Data = unknown, Error = globalThis.Error, Context = unknown>(
  route: MutationRoute,
  options: Omit<UseMutationOptions<Data, Error, RouteVariables, Context>, 'mutationFn'> = {}
) {
  if (!/^(POST|PUT|PATCH|DELETE) \//.test(route)) {
    throw new Error('useRouteMutation requires a POST, PUT, PATCH or DELETE route')
  }
  const runtime = usePod()
  return useMutation({
    ...options,
    mutationFn: ({ params, query, body }: RouteVariables) => {
      const { method, path } = resolveRoute(route, params)
      return runtime.routes.call<Data>({ method, path, query, body })
    }
  })
}

/** Resolve one logical table slot without hiding hooks inside the returned value. */
export function useTable(slotKey: string) {
  const runtime = usePod()
  const binding = runtime.bindings?.[slotKey]
  const capturedTableId = binding?.tableId ?? ''
  const latestTableId = useRef(capturedTableId)
  latestTableId.current = capturedTableId
  const writes = useRecordWrites(capturedTableId)
  return boundTable(slotKey, binding, changes =>
    latestTableId.current === capturedTableId
      ? writes.write.mutateAsync(changes)
      : runtime.base.write(capturedTableId, changes)
  )
}

export function useTableRecords(slotKey: string, query: RecordQuery & { pageSize?: number; enabled?: boolean } = {}) {
  const table = useTable(slotKey)
  const result = useRecords(table.tableId ?? '', {
    ...query,
    enabled: table.configured && (query.enabled ?? true)
  })
  return { ...result, table, configured: table.configured, bindingStatus: table.status }
}

export function useTableAggregate(
  slotKey: string,
  query: AggregateQuery & { groupBy?: AggregateQuery['group_by']; enabled?: boolean }
) {
  const table = useTable(slotKey)
  const result = useAggregate(table.tableId ?? '', {
    ...query,
    enabled: table.configured && (query.enabled ?? true)
  })
  return { ...result, table, configured: table.configured, bindingStatus: table.status }
}

export function useRecordWrites(tableID: string) {
  const runtime = usePod()
  const mutation = useMutation({
    mutationKey: [...runtime.base.key(tableID), 'write'],
    mutationFn: (changes: RecordWrite) => runtime.base.write(tableID, changes)
  })
  return {
    write: mutation,
    create: (data: RecordData | RecordData[]) =>
      mutation.mutateAsync({ creates: (Array.isArray(data) ? data : [data]).map(data => ({ data })) }),
    /** Capture these versions when editing starts; a later refetch must not silently rebase a draft. */
    update: (id: string, data: RecordData, expected_versions: Versions) =>
      mutation.mutateAsync({ updates: [{ id, data, expected_versions }] }),
    remove: (id: string, expected_versions: Versions) => mutation.mutateAsync({ deletes: [{ id, expected_versions }] })
  }
}

export function useChannel(name: string) {
  const runtime = usePod()
  const channel = useRef<EphemeralChannel | null>(null)
  const listeners = useRef(new Set<{ event: string; callback(payload: unknown): void; off?: () => void }>())
  const [presence, setPresence] = useState<PresenceMember[]>([])
  useEffect(() => {
    const current = runtime.channel(name)
    channel.current = current
    for (const listener of listeners.current) listener.off = current.on(listener.event, listener.callback)
    const unsubscribe = current.subscribe(() => setPresence(current.presence()))
    return () => {
      unsubscribe()
      for (const listener of listeners.current) {
        listener.off?.()
        listener.off = undefined
      }
      current.close()
      channel.current = null
    }
  }, [runtime, name])
  return {
    presence,
    broadcast: (event: string, payload: unknown) =>
      channel.current
        ? channel.current.broadcast(event, payload)
        : Promise.reject(new Error(t('pod.content.the_channel_is_not_connected_yet'))),
    on: (event: string, callback: (payload: unknown) => void) => {
      const listener = { event, callback, off: channel.current?.on(event, callback) }
      listeners.current.add(listener)
      return () => {
        listener.off?.()
        listeners.current.delete(listener)
      }
    }
  }
}

class AppletBoundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false }
  static getDerivedStateFromError() {
    return { failed: true }
  }
  componentDidCatch(error: unknown) {
    const host = parent as Window & {
      __ANKOLE_APPLET_HOST__?: { error(frame: Window, error: unknown): void }
    }
    host.__ANKOLE_APPLET_HOST__?.error(window, error)
  }
  render() {
    return this.state.failed ? (
      <p role="alert">{t('pod.content.the_applet_cannot_be_displayed_reload_it_to_continue')}</p>
    ) : (
      this.props.children
    )
  }
}

/** Export the returned value as `provider` from the applet ESM entry. */
export function defineApplet(App: ComponentType) {
  const roots = new WeakMap<Element, { root: Root; node: HTMLDivElement }>()
  return {
    render({ dom, props }: { dom: Element; props: { runtime: AppletRuntime } }) {
      let mounted = roots.get(dom)
      if (!mounted) {
        const rootNode = document.createElement('div')
        rootNode.className = 'ankole-applet'
        dom.appendChild(rootNode)
        mounted = { root: createRoot(rootNode), node: rootNode }
        roots.set(dom, mounted)
      }
      mounted.root.render(
        <QueryClientProvider client={props.runtime.queryClient}>
          <Runtime value={props.runtime}>
            <AppletBoundary>
              <App />
            </AppletBoundary>
          </Runtime>
        </QueryClientProvider>
      )
    },
    destroy({ dom }: { dom: Element }) {
      const mounted = roots.get(dom)
      mounted?.root.unmount()
      mounted?.node.remove()
      roots.delete(dom)
    }
  }
}
