import { createContext, useContext, type ComponentType, type LazyExoticComponent } from 'react'

import type { PluginSlot } from '../common/slots'

export interface AuthChallengeState {
  ready: boolean
  headers: Record<string, string>
}

export interface AuthChallengeSlotProps {
  attemptKey: string
  onChallengeStateChange(state: AuthChallengeState): void
}

export interface AuthAppSlots {
  emailOtpChallenge?: PluginSlot & {
    Component: LazyExoticComponent<ComponentType<AuthChallengeSlotProps>>
  }
}

export const AuthSlotsContext = createContext<AuthAppSlots>({})
export const useAuthSlots = () => useContext(AuthSlotsContext)
