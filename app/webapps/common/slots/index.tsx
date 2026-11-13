import { useBooleanFlagValue } from '@openfeature/react-sdk'
import { createContext, useContext, Suspense, type ReactNode } from 'react'
import type { ConsoleAppSlots } from '../../console/slots'
import type { PodAppSlots } from '../../pod/slots'
import { ErrorBoundary, type ErrorBoundaryVariant } from '../error-boundary'

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
  isVisible?: () => boolean
}

export interface EditionWebappModule {
  id?: string
  console?: ConsoleAppSlots
  pod?: PodAppSlots
}

export function defineWebappModule<const T extends EditionWebappModule>(module: T): T & EditionWebappModule {
  return module
}

export const emptyWebappModule: EditionWebappModule = defineWebappModule({})

export const ActivePluginsContext = createContext<readonly string[]>([])

interface SlotGateProps {
  slot?: PluginSlot
  children(enabled: boolean): ReactNode
}

export function SlotGate({ slot, children }: SlotGateProps) {
  const activePlugins = useContext(ActivePluginsContext)
  if (!slot || !activePlugins.includes(slot.pluginId) || slot.isVisible?.() === false) return children(false)
  return slot.when === undefined ? children(true) : <FeatureGate flagKey={slot.when}>{children}</FeatureGate>
}

function FeatureGate({ flagKey, children }: { flagKey: string; children: SlotGateProps['children'] }) {
  return children(useBooleanFlagValue(flagKey, false))
}

export function SlotBoundary({
  children,
  resetKeys,
  variant
}: {
  children: ReactNode
  resetKeys?: readonly unknown[]
  variant?: ErrorBoundaryVariant
}) {
  return (
    <ErrorBoundary fallback={variant ? undefined : null} resetKeys={resetKeys} variant={variant}>
      <Suspense fallback={null}>{children}</Suspense>
    </ErrorBoundary>
  )
}
