import type { BullXIdentityProviderSyncSink } from '@agentbull/bullx-sdk/plugins'

/**
 * Sync sink for temporary identity-provider adapters used only for setup/OIDC.
 *
 * These adapters need provider-specific validation and login helpers, but they
 * are not the long-running runtime instance that owns directory reconciliation.
 * Dropping sync callbacks here keeps setup/admin auth from accidentally mutating
 * Principals before the real identity-provider runtime has started.
 */
export function createNoopIdentityProviderSyncSink(): BullXIdentityProviderSyncSink {
  return {
    applyFullSync: async () => {},
    upsertUser: async () => {},
    disableUser: async () => {},
    upsertGroup: async () => {},
    deleteGroup: async () => {},
    requestFullSync: async () => {}
  }
}
