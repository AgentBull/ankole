import type { QueryKey, UseMutationOptions } from '@tanstack/react-query'
import { coreConsoleRouteScopes } from '../slots'
import { GLOBAL_LIBRARY_SCOPE, isSiteLibraryDefaults } from './agent-library-capabilities'

const collections = new Set([
  '/',
  '/agents',
  '/drive',
  '/agent-library',
  '/identity',
  '/identity/mappings',
  '/oidc-clients',
  '/access/groups',
  '/access/principals',
  '/signals',
  '/schedules',
  '/schedules/checkbacks',
  '/webhooks',
  '/automation-jobs',
  '/background-agent-jobs',
  '/workers',
  '/conversations',
  '/worker-envs',
  '/settings',
  '/brain/objects',
  '/brain/claims',
  '/brain/contradictions',
  '/brain/merge-suggestions',
  '/brain/sources',
  '/brain/suggestions',
  '/brain/health'
])
const tenantRoots = new Set(
  Object.entries(coreConsoleRouteScopes)
    .filter(([, scope]) => scope === 'tenant')
    .map(([root]) => root)
)

export function consoleTenantPage(path: string, search: URLSearchParams): 'site' | 'collection' | 'record' {
  if (path === '/model-profiles' && search.get('defaults_scope') === 'global') return 'site'
  if (['/brain', '/access'].includes(path)) return 'site'
  if (
    (path === '/settings' || path.startsWith('/settings/') || path.startsWith('/worker-envs/')) &&
    search.get('scope') === 'global'
  ) {
    return 'site'
  }
  if (path === '/agent-library' || path.startsWith('/agent-library/')) {
    const scope = search.get('scope')
    if (scope && scope !== GLOBAL_LIBRARY_SCOPE) return 'record'
    if (isSiteLibraryDefaults(scope || GLOBAL_LIBRARY_SCOPE, search.get('defaults_scope') ?? 'tenant')) return 'site'
  }
  if (collections.has(path)) return 'collection'
  return tenantRoots.has(path.split('/')[1]!) ? 'record' : 'site'
}

export function tenantCollectionPath(path: string): string {
  if (path.startsWith('/access/grants/')) return '/access/principals'
  const candidates = [...collections].filter(
    candidate => candidate !== '/' && (path === candidate || path.startsWith(`${candidate}/`))
  )
  return candidates.sort((a, b) => b.length - a.length)[0] ?? path
}

export function tenantSwitchPath(path: string, hasCurrentTenant: boolean): string {
  const collection = tenantCollectionPath(path)
  return hasCurrentTenant && path !== `${collection}/new` ? collection : path
}

/** Each tenant section calls the generated API with its own request and cache scope. */
export function tenantQueryOptions<T extends { queryKey: QueryKey }>(options: T, tenantID: string): T {
  const [request, ...rest] = options.queryKey
  if (!request || typeof request !== 'object' || !('_id' in request)) {
    throw new Error('A tenant collection requires a generated Console query')
  }
  const headers = new Headers('headers' in request ? (request.headers as HeadersInit) : undefined)
  headers.set('x-ankole-tenant', tenantID)
  return { ...options, queryKey: [{ ...request, headers: Object.fromEntries(headers) }, ...rest] }
}

export function tenantMutationOptions<TData, TError, TVariables, TOnMutateResult>(
  options: UseMutationOptions<TData, TError, TVariables, TOnMutateResult>,
  tenantID: string
): UseMutationOptions<TData, TError, TVariables, TOnMutateResult> {
  const mutate = options.mutationFn
  if (!mutate) return options
  return {
    ...options,
    mutationFn: (variables, context) => {
      if (variables != null && (typeof variables !== 'object' || Array.isArray(variables))) {
        throw new Error('A tenant collection mutation requires generated API options')
      }
      const headers = new Headers(
        variables && typeof variables === 'object' && 'headers' in variables
          ? (variables.headers as HeadersInit)
          : undefined
      )
      headers.set('x-ankole-tenant', tenantID)
      return mutate({ ...variables, headers: Object.fromEntries(headers) } as TVariables, context)
    }
  }
}

export function tenantSearchParams(search: URLSearchParams, tenantID: string): URLSearchParams {
  const prefix = `${tenantID}.`
  return new URLSearchParams(
    [...search].filter(([key]) => key.startsWith(prefix)).map(([key, value]) => [key.slice(prefix.length), value])
  )
}

export function replaceTenantSearch(search: URLSearchParams, tenantID: string, next: URLSearchParams): URLSearchParams {
  const prefix = `${tenantID}.`
  const result = new URLSearchParams([...search].filter(([key]) => !key.startsWith(prefix)))
  for (const [key, value] of next) result.append(`${prefix}${key}`, value)
  return result
}
