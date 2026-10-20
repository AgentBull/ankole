import { t } from 'i18next'
import { Button } from '@ankole/uikit'
import {
  Component,
  createContext,
  useContext,
  useCallback,
  useSyncExternalStore,
  useEffect,
  useRef,
  useState,
  type ComponentType,
  type ReactNode
} from 'react'
import { createRoot, type Root } from 'react-dom/client'
import {
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
import type {
  AggregateQuery,
  AppletRuntime,
  DatabaseRecord,
  EphemeralChannel,
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

const Runtime = createContext<AppletRuntime | null>(null)
export function AppletRuntimeProvider({ runtime, children }: { runtime: AppletRuntime; children: ReactNode }) {
  return <Runtime value={runtime}>{children}</Runtime>
}
export function usePod() {
  const runtime = useContext(Runtime)
  if (!runtime) throw new Error('This component must run inside an Ankole applet')
  return runtime
}

function useTableUpdates(tableID: string) {
  const runtime = usePod()
  const client = useQueryClient()
  const [revoked, setRevoked] = useState(false)
  useEffect(() => {
    setRevoked(false)
    return runtime.database.subscribe(tableID, event => {
      if (event.access_revoked) setRevoked(true)
      const key = runtime.database.key(tableID)
      void client.invalidateQueries({
        queryKey: key,
        predicate: query => query.queryKey[key.length] === 'records' || query.queryKey[key.length] === 'aggregate'
      })
    })
  }, [runtime, tableID, client])
  return { runtime, revoked }
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

// Exposure denial follows the cached Query across component lifetimes. Only an
// actual read success clears it; a manual cache write is not new authorization.
const readDenials = new WeakMap<QueryCache, WeakMap<object, unknown>>()
function queryReadDenials(cache: QueryCache) {
  let denials = readDenials.get(cache)
  if (!denials) {
    denials = new WeakMap()
    readDenials.set(cache, denials)
    const policy = denials
    for (const query of cache.getAll()) {
      const error = [query.state.error, query.state.fetchFailureReason].find(readDenied)
      if (error) policy.set(query, error)
    }
    cache.subscribe(event => {
      if (event.type === 'removed') policy.delete(event.query)
      if (event.type !== 'updated') return
      if (event.action.type === 'success' && !event.action.manual) {
        policy.delete(event.query)
      } else {
        const error = [event.query.state.error, event.query.state.fetchFailureReason].find(readDenied)
        if (error) policy.set(event.query, error)
      }
    })
  }
  return denials
}

function useReadResult<Data, Error>(
  result: UseQueryResult<Data, Error>,
  queryKey: QueryKey,
  revokedError?: Error
): UseQueryResult<Data, Error> {
  const cache = useQueryClient().getQueryCache()
  const query = cache.find({ queryKey, exact: true })!
  const denials = queryReadDenials(cache)
  const subscribe = useCallback(
    (notify: () => void) =>
      cache.subscribe(event => {
        if (event.query === query) notify()
      }),
    [cache, query]
  )
  const snapshot = useCallback(() => denials.get(query) as Error | undefined, [denials, query])
  const denial = useSyncExternalStore(subscribe, snapshot, snapshot)
  const error = revokedError ?? denial ?? [result.error, result.failureReason].find(readDenied)
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

export function useRecords(tableID: string, options: RecordQuery & { pageSize?: number } = {}) {
  const { pageSize, ...rest } = options
  const query: RecordQuery = pageSize === undefined ? rest : { ...rest, page_size: pageSize }
  const { runtime, revoked } = useTableUpdates(tableID)
  const queryKey = [...runtime.database.key(tableID), 'records', query]
  const read = useQuery({
    queryKey,
    queryFn: () => runtime.database.records(tableID, query),
    enabled: !revoked
  })
  const records = useReadResult(
    read,
    queryKey,
    revoked ? new Error(t('pod.content.you_no_longer_have_access_to_this_table')) : undefined
  )
  const write = useRecordWrites(tableID)
  const pending = useMutationState({
    filters: { mutationKey: [...runtime.database.key(tableID), 'write'], status: 'pending' },
    select: mutation => mutation.state.variables as RecordWrite
  })
  const preview = records.data && {
    ...records.data,
    records: records.data.records.map(record =>
      pending.reduce((preview, changes) => {
        const update = changes.updates?.find(item => item.id === record.id)
        return update ? { ...preview, data: { ...preview.data, ...update.data } } : preview
      }, record)
    )
  }
  return {
    ...records,
    data: preview,
    ...write
  }
}

export function useAggregate(tableID: string, options: AggregateQuery & { groupBy?: AggregateQuery['group_by'] }) {
  const { groupBy, ...rest } = options
  const query = groupBy === undefined ? rest : { ...rest, group_by: groupBy }
  const { runtime, revoked } = useTableUpdates(tableID)
  const queryKey = [...runtime.database.key(tableID), 'aggregate', query]
  const result = useQuery({
    queryKey,
    queryFn: () => runtime.database.aggregate(tableID, query),
    enabled: !revoked
  })
  return useReadResult(
    result,
    queryKey,
    revoked ? new Error(t('pod.content.you_no_longer_have_access_to_this_table')) : undefined
  )
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

/** Record versions come from this read, including absence of an unwritten field. */
export function expectedVersions(record: DatabaseRecord, data: RecordData) {
  return Object.fromEntries(
    Object.keys(data)
      .filter(id => Object.hasOwn(record.versions, id))
      .map(id => [id, record.versions[id]!])
  )
}

export function useRecordWrites(tableID: string) {
  const runtime = usePod()
  const client = useQueryClient()
  const mutation = useMutation({
    mutationKey: [...runtime.database.key(tableID), 'write'],
    mutationFn: (changes: RecordWrite) => runtime.database.write(tableID, changes),
    onSettled: () => client.invalidateQueries({ queryKey: runtime.database.key(tableID) })
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
  render() {
    return this.state.failed ? (
      <div className="space-y-2">
        <p role="alert">{t('pod.content.the_applet_cannot_be_displayed_reload_it_to_continue')}</p>
        <Button size="sm" variant="outline" onClick={() => this.setState({ failed: false })}>
          {t('pod.content.reload_applet')}
        </Button>
      </div>
    ) : (
      this.props.children
    )
  }
}

/** Export the returned value as `provider` from the applet CommonJS entry. */
export function defineApplet(App: ComponentType) {
  const roots = new WeakMap<Element, { root: Root; node: HTMLDivElement }>()
  return {
    render({ dom, props }: { dom: Element; props: { runtime: AppletRuntime } }) {
      const previous = roots.get(dom)
      previous?.root.unmount()
      previous?.node.remove()
      const rootNode = document.createElement('div')
      rootNode.className = 'ankole-applet'
      dom.appendChild(rootNode)
      const root = createRoot(rootNode)
      roots.set(dom, { root, node: rootNode })
      root.render(
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
