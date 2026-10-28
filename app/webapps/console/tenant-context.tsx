import { TableCell, TableRow as BaseTableRow } from '@ankole/uikit'
import {
  useInfiniteQuery as useBaseInfiniteQuery,
  useMutation as useBaseMutation,
  useQuery as useBaseQuery
} from '@tanstack/react-query'
import { Link as RouterLink, useNavigate as useBaseNavigate, useRouter, type AnyRouter } from '@tanstack/react-router'
import { createContext, useContext, type ComponentProps, type ReactNode } from 'react'
import { toURLSearchParams, useSearchParams as useBaseSearchParams } from '../common/router'
import { selectDataTenant } from '../common/browser-session'
import {
  replaceTenantSearch,
  tenantMutationOptions,
  tenantQueryOptions,
  tenantSearchParams
} from './state/tenant-scope'

export interface ConsoleTenant {
  id: string
  display_name: string
  slug: string
  first: boolean
}

export const ConsoleTenantContext = createContext<ConsoleTenant | null>(null)
const TenantRowContext = createContext<ConsoleTenant | null>(null)
export const useConsoleTenant = () => useContext(ConsoleTenantContext)

export const useQuery = ((options, client) => {
  const tenant = useConsoleTenant()
  return useBaseQuery(tenant ? tenantQueryOptions(options, tenant.id) : options, client)
}) as typeof useBaseQuery

export const useInfiniteQuery = ((options, client) => {
  const tenant = useConsoleTenant()
  return useBaseInfiniteQuery(tenant ? tenantQueryOptions(options, tenant.id) : options, client)
}) as typeof useBaseInfiniteQuery

export const useMutation: typeof useBaseMutation = (options, client) => {
  const tenant = useConsoleTenant()
  return useBaseMutation(tenant ? tenantMutationOptions(options, tenant.id) : options, client)
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

/** A record link preserves its owner scope when it opens a new document. */
export const Link = ((props: ComponentProps<typeof RouterLink>) => {
  const tenant = useConsoleTenant()
  const router = useRouter()
  if (!tenant) return <RouterLink {...props} />
  const current = Object.fromEntries(
    tenantSearchParams(new URLSearchParams(router.latestLocation.searchStr), tenant.id)
  )
  const search =
    typeof props.search === 'function'
      ? Reflect.apply(props.search, undefined, [current])
      : props.search === true
        ? current
        : props.search
  const siteGlobal = search && typeof search === 'object' && 'scope' in search && search.scope === 'global'
  return (
    <RouterLink<AnyRouter, string, string, string, string>
      {...props}
      reloadDocument
      search={siteGlobal ? search : { ...search, data_tenant: tenant.id }}
    />
  )
}) as typeof RouterLink

export const useNavigate: typeof useBaseNavigate = defaults => {
  const navigate = useBaseNavigate(defaults)
  const router = useRouter()
  const tenant = useConsoleTenant()
  return options => {
    if (!tenant) return navigate(options)
    const target = router.buildLocation({ ...defaults, ...options } as Parameters<typeof router.buildLocation>[0])
    selectDataTenant(tenant.id, target.href)
    return Promise.resolve()
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
