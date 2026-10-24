import type { JsonObject } from '@agentbull/active-support'
import { batch, createModel, signal } from '@preact/signals-react'
import type { PodAdminSettingsResponse } from '../api/generated/types.gen'

export const PodSettingsModel = createModel(() => {
  const expiry = new Date(Date.now() + 7 * 86400000)
  const localExpiry = new Date(expiry.getTime() - expiry.getTimezoneOffset() * 60000).toISOString().slice(0, 16)
  const source = signal<string>()
  const displayName = signal('')
  const guests = signal(true)
  const policy = signal<PodAdminSettingsResponse['loginPolicy']>({
    allow_email_otp: true,
    allow_member_credential_change: true,
    require_sso_for_members: false,
    allow_invite_links: true,
    allowed_email_domains: []
  })
  const domains = signal('')
  return {
    displayName,
    guests,
    policy,
    domains,
    initialize(key: string, data: PodAdminSettingsResponse) {
      if (source.value === key) return
      batch(() => {
        source.value = key
        displayName.value = data.displayName
        guests.value = data.allowExternalGuests
        policy.value = data.loginPolicy
        domains.value = data.loginPolicy.allowed_email_domains.join(', ')
      })
    },
    section: signal('general'),
    memberName: signal(''),
    memberEmail: signal(''),
    membership: signal<'member' | 'guest'>('member'),
    selectedUID: signal(''),
    memberAction: signal<'suspended' | 'offboarded' | 'restore'>('suspended'),
    reason: signal(''),
    identityVerified: signal(false),
    invitationEmail: signal(''),
    invitationRole: signal<'member' | 'guest'>('member'),
    expiresAt: signal(localExpiry),
    maxUses: signal('1'),
    adapterID: signal(''),
    providerID: signal(''),
    enabled: signal(true),
    config: signal<JsonObject>({}),
    preservedSecrets: signal<string[]>([])
  }
})
