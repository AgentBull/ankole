import { createContext, useContext, type ComponentType, type LazyExoticComponent } from 'react'

import { validateSlotIDs, type PluginSlot } from '../common/slots'

export type ConsoleRouteScope = 'site' | 'tenant'

export interface ConsoleRouteSlot extends PluginSlot {
  id: string
  path: string
  scope: ConsoleRouteScope
  Component: LazyExoticComponent<ComponentType>
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

export const coreConsoleRouteRoots = [
  'agents',
  'tenants',
  'agent-library',
  'brain',
  'providers',
  'identity',
  'oidc-clients',
  'access',
  'signals',
  'schedules',
  'webhooks',
  'automation-jobs',
  'settings',
  'worker-providers',
  'worker-envs',
  'workers',
  'background-agent-jobs',
  'conversations',
  '$'
] as const

export function normalizeConsoleSlotPath(path: string): string {
  return path.replace(/^\/+|\/+$/g, '')
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
}
