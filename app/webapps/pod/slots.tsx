import { createContext, useContext, type ComponentType, type LazyExoticComponent, type ReactNode } from 'react'

import type { PluginSlot } from '../common/slots'

export interface PodSettingsTabSlot extends PluginSlot {
  id: string
  labelKey: string
  Component: LazyExoticComponent<ComponentType>
}

export interface PodAppSlots {
  accountNavigation?: PluginSlot & { content: ReactNode }
  settingsTabs?: readonly PodSettingsTabSlot[]
}

export const PodSlotsContext = createContext<PodAppSlots>({})
export const usePodSlots = () => useContext(PodSlotsContext)
export const podSettingsSections = ['general', 'members', 'agents', 'invitations', 'providers'] as const
