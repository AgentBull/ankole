import { useBooleanFlagValue } from '@openfeature/react-sdk'
import { createContext, useContext, Suspense, type ReactNode } from 'react'

export function validateSlotIDs(slots: readonly { id: string }[], reserved: readonly string[]): void {
  const ids = new Set(reserved)
  for (const { id } of slots) {
    if (!id || ids.has(id)) throw new Error(`Duplicate or reserved slot ID: ${id}`)
    ids.add(id)
  }
}

export interface PluginSlot {
  pluginId: string
  when?: string
}

export const ActivePluginsContext = createContext<readonly string[]>([])

interface SlotGateProps {
  slot?: PluginSlot
  children(enabled: boolean): ReactNode
}

export function SlotGate({ slot, children }: SlotGateProps) {
  const activePlugins = useContext(ActivePluginsContext)
  if (!slot || !activePlugins.includes(slot.pluginId)) return children(false)
  return slot.when === undefined ? children(true) : <FeatureGate flagKey={slot.when}>{children}</FeatureGate>
}

function FeatureGate({ flagKey, children }: { flagKey: string; children: SlotGateProps['children'] }) {
  return children(useBooleanFlagValue(flagKey, false))
}

export function SlotBoundary({ children }: { children: ReactNode }) {
  return <Suspense fallback={null}>{children}</Suspense>
}
