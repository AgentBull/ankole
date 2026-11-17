import { TableCell, TableRow as BaseTableRow } from '@ankole/uikit'
import {
  type QueryClient,
  useInfiniteQuery as useBaseInfiniteQuery,
  useMutation as useBaseMutation,
  useQuery as useBaseQuery
} from '@tanstack/react-query'
import {
  Link as RouterLink,
  useLocation,
  useNavigate as useBaseNavigate,
  useRouter,
  type AnyRouter
} from '@tanstack/react-router'
import { createContext, useContext, useEffect, useSyncExternalStore, type ComponentProps, type ReactNode } from 'react'
import { toURLSearchParams, useSearchParams as useBaseSearchParams } from '../common/router'
import { dataTenantID, setDataTenantSoft, subscribeDataTenant } from '../common/browser-session'
import { fromDocument } from './api/json-api'
import * as siteQueries from './api/v2-site/generated/@tanstack/react-query.gen'
import {
  consoleTenantPage,
  replaceTenantSearch,
  SITE_QUERY_IDS,
  tenantMutationOptions,
  tenantQueryOptions,
  tenantSearchParams
} from './state/tenant-scope'

export { SITE_QUERY_IDS }

export interface ConsoleTenant {
  id: string
  display_name: string
  slug: string
  first: boolean
}

export const ConsoleTenantContext = createContext<ConsoleTenant | null>(null)
export const ConsoleBoundTenantIDContext = createContext<string | null>(null)
const TenantRowContext = createContext<ConsoleTenant | null>(null)
export const useConsoleTenant = () => useContext(ConsoleTenantContext)
export const useBoundTenantID = (): string | null => {
  const tenant = useConsoleTenant()
  const boundTenantID = useContext(ConsoleBoundTenantIDContext)
  return tenant?.id ?? boundTenantID
}

export function useSelectedDataTenantID(): string | null {
  return useSyncExternalStore(subscribeDataTenant, dataTenantID, dataTenantID)
}

export function useEffectiveDataTenantID(enabled = true): string | null {
  const selected = useSelectedDataTenantID()
  const location = useLocation()
  const tenants = useBaseQuery({
    ...siteQueries.listTenantsOptions(),
    select: document => fromDocument(document),
    enabled
  })
  const items = tenants.data?.filter(tenant => !tenant.deleting_at) ?? []
  const explicitAll = new URLSearchParams(location.searchStr).get('data_tenant') === ''
  const soleTenantID = !explicitAll && tenants.isSuccess && items.length === 1 ? (items[0]?.id ?? null) : null

  useEffect(() => {
    if (enabled && !selected && soleTenantID) {
      setDataTenantSoft(soleTenantID)
    }
  }, [enabled, selected, soleTenantID])

  return selected ?? soleTenantID
}

export interface HistoryTenantTracker {
  resolve: (location: {
    pathname: string
    searchStr: string
    state?: { __TSR_key?: string; key?: string; __TSR_index?: number }
  }) => string | null
  peek: (entryKey: string | undefined) => string | null | undefined
}

let activeHistoryTenantTracker: HistoryTenantTracker | null = null

export function peekActiveHistoryTenant(entryKey: string | undefined): string | null | undefined {
  return activeHistoryTenantTracker?.peek(entryKey)
}

export function createHistoryTenantTracker(initialTenant: string | null = dataTenantID()): HistoryTenantTracker {
  const entryTenants = new Map<string, string | null>()
  let lastIndex: number | undefined

  const tracker: HistoryTenantTracker = {
    resolve(location) {
      const params = new URLSearchParams(location.searchStr)
      const entryKey = location.state?.__TSR_key ?? location.state?.key
      const entryIndex = location.state?.__TSR_index
      const currentTenant = dataTenantID()

      let nextTenant: string | null
      if (params.has('data_tenant')) {
        nextTenant = params.get('data_tenant') || null
      } else if (entryKey && entryTenants.has(entryKey)) {
        nextTenant = entryTenants.get(entryKey) ?? null
      } else if (entryTenants.size === 0) {
        nextTenant = initialTenant
      } else if (
        typeof entryIndex === 'number' &&
        lastIndex !== undefined &&
        entryIndex < lastIndex &&
        consoleTenantPage(location.pathname, params) !== 'site'
      ) {
        nextTenant = null
      } else {
        nextTenant = currentTenant
      }

      if (entryKey) entryTenants.set(entryKey, nextTenant)
      if (typeof entryIndex === 'number') lastIndex = entryIndex
      return nextTenant
    },
    peek(entryKey) {
      return entryKey && entryTenants.has(entryKey) ? (entryTenants.get(entryKey) ?? null) : undefined
    }
  }

  activeHistoryTenantTracker = tracker
  return tracker
}

export function createTenantNavigationHandler(client: QueryClient) {
  const tracker = createHistoryTenantTracker()
  return ({ location, preload }: { location: Parameters<HistoryTenantTracker['resolve']>[0]; preload: boolean }) => {
    if (preload) return
    const nextTenant = tracker.resolve(location)
    if (nextTenant !== dataTenantID()) {
      setDataTenantSoft(nextTenant)
      evictTenantScopedQueries(client)
    }
  }
}

/** Evicts cached single-tenant queries whose headers rely on the implicit sessionStorage data tenant. */
export function evictTenantScopedQueries(queryClient: QueryClient): void {
  const predicate = ({ queryKey }: { queryKey: readonly unknown[] }) => {
    const first = queryKey[0]
    if (!first || typeof first !== 'object' || !('_id' in first)) return false
    const record = first as { _id?: unknown; headers?: Record<string, string> }
    if (typeof record._id !== 'string' || SITE_QUERY_IDS.has(record._id)) return false
    if (record.headers && 'x-ankole-tenant' in record.headers) return false
    return true
  }
  queryClient.removeQueries({ predicate })
}

export const useQuery = ((options, client) => {
  const boundTenantID = useBoundTenantID()
  return useBaseQuery(boundTenantID ? tenantQueryOptions(options, boundTenantID) : options, client)
}) as typeof useBaseQuery

export const useInfiniteQuery = ((options, client) => {
  const boundTenantID = useBoundTenantID()
  return useBaseInfiniteQuery(boundTenantID ? tenantQueryOptions(options, boundTenantID) : options, client)
}) as typeof useBaseInfiniteQuery

export const useMutation: typeof useBaseMutation = (options, client) => {
  const boundTenantID = useBoundTenantID()
  return useBaseMutation(boundTenantID ? tenantMutationOptions(options, boundTenantID) : options, client)
}

/** A section owns its filters and cursors while the aggregate page owns the tenant filter. */
export const useSearchParams: typeof useBaseSearchParams = () => {
  const tenant = useConsoleTenant()
  const [search, setSearch] = useBaseSearchParams()
  if (!tenant) return [search, setSearch]
  return [
    tenantSearchParams(search, tenant.id),
    (next, options) =>
      setSearch(current => {
        const owned = tenantSearchParams(current, tenant.id)
        const resolved = typeof next === 'function' ? next(owned) : toURLSearchParams(next)
        return replaceTenantSearch(current, tenant.id, resolved)
      }, options)
  ]
}

type SearchTransform = (prev: Record<string, string>) => Record<string, unknown>

function resolveLinkSearch(
  searchProp: ComponentProps<typeof RouterLink>['search'],
  current: Record<string, string>
): Record<string, unknown> | undefined {
  if (typeof searchProp === 'function') {
    const transform = searchProp as SearchTransform
    return transform(current)
  }
  if (searchProp === true) return current
  return searchProp as Record<string, unknown> | undefined
}

/** A record link preserves its owner scope across SPA transitions and new tabs. */
export const Link = ((props: ComponentProps<typeof RouterLink>) => {
  const tenant = useConsoleTenant()
  const boundTenantID = useBoundTenantID()
  const router = useRouter()
  const selectedTenantID = useSelectedDataTenantID()
  const tenantID = boundTenantID ?? selectedTenantID
  if (!tenantID) return <RouterLink {...props} />
  const params = new URLSearchParams(router.latestLocation.searchStr)
  const current = Object.fromEntries(tenant ? tenantSearchParams(params, tenant.id) : params)
  const search = resolveLinkSearch(props.search, current)
  const target = router.buildLocation({ ...props, search } as Parameters<typeof router.buildLocation>[0])
  const site = consoleTenantPage(target.pathname, new URLSearchParams(target.searchStr)) === 'site'
  return (
    <RouterLink<AnyRouter, string, string, string, string>
      {...props}
      reloadDocument={props.reloadDocument}
      search={site ? search : { ...search, data_tenant: tenantID }}
    />
  )
}) as typeof RouterLink

export const useNavigate: typeof useBaseNavigate = defaults => {
  const navigate = useBaseNavigate(defaults)
  const router = useRouter()
  const boundTenantID = useBoundTenantID()
  return options => {
    if (!boundTenantID) return navigate(options)
    const target = router.buildLocation({ ...defaults, ...options } as Parameters<typeof router.buildLocation>[0])
    const site = consoleTenantPage(target.pathname, new URLSearchParams(target.searchStr)) === 'site'
    if (site || boundTenantID === dataTenantID()) return navigate(options)
    const targetSearch = Object.fromEntries(new URLSearchParams(target.searchStr))
    return router.navigate<AnyRouter, string, string, string, string>({
      to: target.pathname,
      hash: target.hash || undefined,
      replace: options.replace,
      resetScroll: options.resetScroll,
      search: { ...targetSearch, data_tenant: boundTenantID }
    })
  }
}

export function TenantTableRows({ children }: { children: ReactNode }) {
  return <TenantRowContext value={useConsoleTenant()}>{children}</TenantRowContext>
}

export function TableRow({ children, ...props }: ComponentProps<typeof BaseTableRow>) {
  const tenant = useContext(TenantRowContext)
  return (
    <BaseTableRow {...props}>
      {tenant ? <TableCell title={tenant.slug}>{tenant.display_name}</TableCell> : null}
      {children}
    </BaseTableRow>
  )
}
