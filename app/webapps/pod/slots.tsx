import { createContext, useContext, type ComponentType, type LazyExoticComponent, type ReactNode } from 'react'

import { emptyWebappModule, validateSlotIDs, type EditionWebappModule, type PluginSlot } from '../common/slots'

export type PodAccountNavigationSlot = PluginSlot & { content: ReactNode }

export interface PodSettingsTabSlot extends PluginSlot {
  id: string
  labelKey: string
  icon?: ComponentType<{ className?: string }>
  Component: LazyExoticComponent<ComponentType>
}

export interface PodAppSlots {
  accountNavigation?: PodAccountNavigationSlot
  accountNavigations?: readonly PodAccountNavigationSlot[]
  settingsTabs?: readonly PodSettingsTabSlot[]
}

export const PodSlotsContext = createContext<PodAppSlots>({})
export const usePodSlots = () => useContext(PodSlotsContext)
export const podSettingsSections = ['general', 'members', 'agents', 'invitations', 'providers', 'environment'] as const

export function mergePodSlots(...sources: readonly (PodAppSlots | undefined)[]): PodAppSlots {
  const accountNavigations: PodAccountNavigationSlot[] = []
  const settingsTabs: PodSettingsTabSlot[] = []

  for (const source of sources) {
    if (!source) continue
    if (source.accountNavigation) accountNavigations.push(source.accountNavigation)
    if (source.accountNavigations) accountNavigations.push(...source.accountNavigations)
    if (source.settingsTabs) settingsTabs.push(...source.settingsTabs)
  }

  return {
    ...(accountNavigations.length > 0 ? { accountNavigations } : {}),
    ...(settingsTabs.length > 0 ? { settingsTabs } : {})
  }
}

export function validatePodSlots(slots: PodAppSlots): void {
  validateSlotIDs(slots.settingsTabs ?? [], [...podSettingsSections, 'connectors'])
}

export function resolvePodSlots(slots?: PodAppSlots, modules: readonly EditionWebappModule[] = []): PodAppSlots {
  const merged = mergePodSlots(emptyWebappModule.pod, ...modules.map(mod => mod.pod), slots)
  validatePodSlots(merged)
  return merged
}
