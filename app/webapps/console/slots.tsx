import type { QueryClient } from '@tanstack/react-query'
import { createMemoryHistory, createRootRoute, createRoute, createRouter } from '@tanstack/react-router'
import { createContext, useContext, type ComponentType, type FunctionComponent } from 'react'

import { emptyWebappModule, validateSlotIDs, type EditionWebappModule, type PluginSlot } from '../common/slots'

export type ConsoleRouteScope = 'site' | 'tenant'

export interface ConsoleRouteLoaderContext {
  queryClient: QueryClient
  params: Readonly<Record<string, string>>
  location: {
    pathname: string
    searchStr: string
  }
  scope: ConsoleRouteScope
  tenantID: string | null
}

export interface ConsoleRouteSlot extends PluginSlot {
  id: string
  path: string
  scope: ConsoleRouteScope
  /**
   * Optional tenant page classification when `scope === 'tenant'`.
   * Defaults to `'record'` when `path` contains a `$param` segment or ends with `/new`,
   * and `'collection'` otherwise.
   */
  tenantPage?: 'collection' | 'record'
  /**
   * Optional parent collection path for a tenant `'record'` route when switching tenants.
   */
  collectionPath?: string
  /**
   * Optional data loader executed alongside `load` before the route commits.
   */
  loader?: (context: ConsoleRouteLoaderContext) => Promise<unknown>
  /** Imports the page's code; the router loads it before committing the route, as it does for built-in pages. */
  load: () => Promise<{ default: FunctionComponent }>
}

declare module '@tanstack/react-router' {
  interface StaticDataRouteOption {
    consoleSlot?: ConsoleRouteSlot
  }
}

export interface ConsoleNavItemSlot {
  id: string
  to: string
  match?: string
  label: string
  icon: ComponentType<{ className?: string }>
  when?: string
  isVisible?: () => boolean
}

export interface ConsoleNavSectionSlot extends PluginSlot {
  id: string
  /** Matches an existing core navigation section label key to append items, or declares a new section. */
  label?: string
  items: readonly ConsoleNavItemSlot[]
}

export interface ConsoleAppSlots {
  routes?: readonly ConsoleRouteSlot[]
  navSections?: readonly ConsoleNavSectionSlot[]
}

export const ConsoleSlotsContext = createContext<ConsoleAppSlots>({})
export const useConsoleSlots = () => useContext(ConsoleSlotsContext)

export const coreConsoleRouteScopes = {
  agents: 'tenant',
  drive: 'tenant',
  tenants: 'site',
  'agent-library': 'tenant',
  'model-profiles': 'tenant',
  brain: 'tenant',
  providers: 'site',
  identity: 'tenant',
  'oidc-clients': 'tenant',
  access: 'tenant',
  signals: 'tenant',
  schedules: 'tenant',
  webhooks: 'tenant',
  'automation-jobs': 'tenant',
  settings: 'tenant',
  'worker-providers': 'site',
  'worker-envs': 'tenant',
  workers: 'tenant',
  'background-agent-jobs': 'tenant',
  conversations: 'tenant',
  'ai-usage': 'tenant',
  $: 'site'
} as const satisfies Record<string, ConsoleRouteScope>

export const coreConsoleRouteRoots = Object.keys(coreConsoleRouteScopes)

let activeConsoleRouteSlots: readonly ConsoleRouteSlot[] = []
let activeConsoleSlotRouter:
  | {
      matchRoutes(
        pathname: string,
        locationSearch: Record<string, unknown>
      ): readonly {
        staticData?: { consoleSlot?: ConsoleRouteSlot }
      }[]
    }
  | undefined

export function normalizeConsoleSlotPath(path: string): string {
  return path.replace(/^\/+|\/+$/g, '')
}

export function consoleSlotPageKind(route: Pick<ConsoleRouteSlot, 'path' | 'tenantPage'>): 'collection' | 'record' {
  if (route.tenantPage) return route.tenantPage
  const normalized = normalizeConsoleSlotPath(route.path)
  return normalized.includes('$') || normalized.endsWith('/new') ? 'record' : 'collection'
}

export function mergeConsoleSlots(...sources: readonly (ConsoleAppSlots | undefined)[]): ConsoleAppSlots {
  const routes: ConsoleRouteSlot[] = []
  const navSections: ConsoleNavSectionSlot[] = []

  for (const source of sources) {
    if (!source) continue
    if (source.routes) routes.push(...source.routes)
    if (source.navSections) {
      for (const section of source.navSections) {
        const existingIndex = navSections.findIndex(
          candidate => candidate.id === section.id && candidate.pluginId === section.pluginId
        )
        if (existingIndex >= 0) {
          const existing = navSections[existingIndex]!
          if (existing.label !== undefined && section.label !== undefined && existing.label !== section.label) {
            throw new Error(`Conflicting Console navSection label for "${section.id}"`)
          }
          if (existing.when !== undefined && section.when !== undefined && existing.when !== section.when) {
            throw new Error(`Conflicting Console navSection when flag for "${section.id}"`)
          }
          const existingVisible = existing.isVisible
          const nextVisible = section.isVisible
          const isVisible =
            existingVisible && nextVisible ? () => existingVisible() && nextVisible() : (existingVisible ?? nextVisible)
          const label = existing.label ?? section.label
          const when = existing.when ?? section.when
          navSections[existingIndex] = {
            id: existing.id,
            pluginId: existing.pluginId,
            ...(label !== undefined ? { label } : {}),
            ...(when !== undefined ? { when } : {}),
            ...(isVisible !== undefined ? { isVisible } : {}),
            items: [...existing.items, ...section.items]
          }
        } else {
          navSections.push({ ...section, items: [...section.items] })
        }
      }
    }
  }

  return {
    ...(routes.length > 0 ? { routes } : {}),
    ...(navSections.length > 0 ? { navSections } : {})
  }
}

export function validateConsoleSlots(slots: ConsoleAppSlots): void {
  const routes = slots.routes ?? []
  validateSlotIDs(routes, coreConsoleRouteRoots)

  const seenPaths = new Set<string>()
  const reservedRoots = new Set<string>(coreConsoleRouteRoots)
  for (const route of routes) {
    const normalized = normalizeConsoleSlotPath(route.path)
    const [root = ''] = normalized.split('/')
    if (!normalized || reservedRoots.has(root) || seenPaths.has(normalized)) {
      throw new Error(`Invalid or colliding Console route path: ${route.path}`)
    }
    seenPaths.add(normalized)
  }

  const navSections = slots.navSections ?? []
  validateSlotIDs(navSections, ['home', 'work', 'capabilities', 'connections', 'platform'])
  validateSlotIDs(
    navSections.flatMap(section => section.items),
    coreConsoleRouteRoots
  )

  activeConsoleRouteSlots = [...routes]
  if (routes.length === 0) {
    activeConsoleSlotRouter = undefined
  } else {
    const rootRoute = createRootRoute()
    const bodyRoute = createRoute({ getParentRoute: () => rootRoute, id: 'console-body' })
    const routeTree = rootRoute.addChildren([
      bodyRoute.addChildren(
        routes.map(route =>
          createRoute({
            getParentRoute: () => bodyRoute,
            path: normalizeConsoleSlotPath(route.path),
            staticData: { consoleSlot: route }
          })
        )
      )
    ])
    activeConsoleSlotRouter = createRouter({ routeTree, history: createMemoryHistory() })
  }
}

export function resolveConsoleSlots(
  slots?: ConsoleAppSlots,
  modules: readonly EditionWebappModule[] = []
): ConsoleAppSlots {
  const merged = mergeConsoleSlots(emptyWebappModule.console, ...modules.map(mod => mod.console), slots)
  validateConsoleSlots(merged)
  return merged
}

function matchConsoleRouteSlot(path: string): ConsoleRouteSlot | undefined {
  const normalized = normalizeConsoleSlotPath(path)
  if (!normalized || !activeConsoleSlotRouter) return undefined
  const matches = activeConsoleSlotRouter.matchRoutes(`/${normalized}`, {})
  return matches.at(-1)?.staticData?.consoleSlot
}

export function consoleSlotTenantPage(path: string): 'site' | 'collection' | 'record' | undefined {
  const matched = matchConsoleRouteSlot(path)
  if (matched) {
    return matched.scope === 'site' ? 'site' : consoleSlotPageKind(matched)
  }
  const collection = consoleSlotCollectionPath(path)
  return collection
    ? normalizeConsoleSlotPath(path).toLowerCase() === normalizeConsoleSlotPath(collection).toLowerCase()
      ? 'collection'
      : 'record'
    : undefined
}

export function consoleSlotCollectionPath(path: string): string | undefined {
  const matched = matchConsoleRouteSlot(path)
  if (matched) {
    if (matched.scope === 'site') return undefined
    if (matched.collectionPath) return `/${normalizeConsoleSlotPath(matched.collectionPath)}`
    if (consoleSlotPageKind(matched) === 'collection') return `/${normalizeConsoleSlotPath(matched.path)}`
  }

  const normalizedTarget = `/${normalizeConsoleSlotPath(path).toLowerCase()}`
  const collections = new Map<string, string>()
  for (const route of activeConsoleRouteSlots) {
    if (route.scope !== 'tenant') continue
    if (route.collectionPath) {
      const canonical = `/${normalizeConsoleSlotPath(route.collectionPath)}`
      collections.set(canonical.toLowerCase(), canonical)
    }
    if (consoleSlotPageKind(route) === 'collection') {
      const canonical = `/${normalizeConsoleSlotPath(route.path)}`
      collections.set(canonical.toLowerCase(), canonical)
    } else {
      const segments = normalizeConsoleSlotPath(route.path).split('/').filter(Boolean)
      const dynamicIndex = segments.findIndex(segment => segment.includes('$') || segment === 'new')
      if (dynamicIndex > 0) {
        const canonical = `/${segments.slice(0, dynamicIndex).join('/')}`
        collections.set(canonical.toLowerCase(), canonical)
      }
    }
  }

  const candidates = [...collections.entries()].filter(
    ([lower]) => lower !== '/' && (normalizedTarget === lower || normalizedTarget.startsWith(`${lower}/`))
  )
  return candidates.sort(([a], [b]) => b.length - a.length)[0]?.[1]
}
