import type { JsonObject } from '@agentbull/active-support'
import { batch, computed, createModel, signal } from '@preact/signals-react'
import type { PodAdminSettingsResponse } from '../api/generated/types.gen'

export type InvitationExpiryPreset = '24h' | '7d' | '30d' | 'custom'

export type NormalizedLoginPolicy = {
  allow_email_otp: boolean
  allow_member_credential_change: boolean
  require_sso_for_members: boolean
  allow_invite_links: boolean
  allowed_email_domains: string[]
}

export type ConfirmUnbindMemberCredential = {
  uid: string
  id: string
  identifier: string
  memberName: string
}

export function parseAllowedDomains(value: string): string[] {
  return value
    .split(',')
    .map(item => item.trim().toLowerCase())
    .filter(Boolean)
}

export function normalizeLoginPolicy(
  policy: Partial<PodAdminSettingsResponse['loginPolicy']> | undefined
): NormalizedLoginPolicy {
  return {
    allow_email_otp: policy?.allow_email_otp === true,
    allow_member_credential_change: policy?.allow_member_credential_change === true,
    require_sso_for_members: policy?.require_sso_for_members === true,
    allow_invite_links: policy?.allow_invite_links === true,
    allowed_email_domains: (policy?.allowed_email_domains ?? []).map(item => item.trim().toLowerCase()).filter(Boolean)
  }
}

export function resolveInvitationExpiryISO(
  preset: InvitationExpiryPreset,
  customLocal: string,
  now = Date.now()
): string {
  switch (preset) {
    case '24h':
      return new Date(now + 24 * 3_600_000).toISOString()
    case '7d':
      return new Date(now + 7 * 86_400_000).toISOString()
    case '30d':
      return new Date(now + 30 * 86_400_000).toISOString()
    case 'custom':
      return new Date(customLocal).toISOString()
  }
}

export function formatPermissionCondition(condition: unknown): string | undefined {
  if (condition === null || condition === undefined || condition === true) return undefined
  if (typeof condition === 'string') {
    const trimmed = condition.trim()
    return trimmed === '' || trimmed === 'true' ? undefined : trimmed
  }
  if (typeof condition === 'object' && !Array.isArray(condition) && Object.keys(condition).length === 0) {
    return undefined
  }
  return JSON.stringify(condition)
}

function defaultLocalExpiry(now = Date.now()): string {
  const expiry = new Date(now + 7 * 86_400_000)
  return new Date(expiry.getTime() - expiry.getTimezoneOffset() * 60_000).toISOString().slice(0, 16)
}

export const PodSettingsModel = createModel(() => {
  const source = signal<string>()
  const savedSettings = signal<{
    displayName: string
    allowExternalGuests: boolean
    loginPolicy: NormalizedLoginPolicy
  }>()
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
  const precreateOpen = signal(false)
  const memberName = signal('')
  const memberEmail = signal('')
  const membership = signal<'member' | 'guest'>('member')
  const invitationEmail = signal('')
  const invitationRole = signal<'member' | 'guest'>('member')
  const expiryPreset = signal<InvitationExpiryPreset>('7d')
  const expiresAt = signal(defaultLocalExpiry())
  const maxUses = signal('')
  const maxUsesCustomized = signal(false)
  const adapterID = signal('')
  const editingProviderID = signal<string>()
  const providerID = signal('')
  const enabled = signal(true)
  const config = signal<JsonObject>({})
  const preservedSecrets = signal<string[]>([])

  const commitSaved = (data: Pick<PodAdminSettingsResponse, 'displayName' | 'allowExternalGuests' | 'loginPolicy'>) => {
    const normalized = normalizeLoginPolicy(data.loginPolicy)
    batch(() => {
      savedSettings.value = {
        displayName: data.displayName,
        allowExternalGuests: Boolean(data.allowExternalGuests),
        loginPolicy: normalized
      }
      displayName.value = data.displayName
      guests.value = Boolean(data.allowExternalGuests)
      policy.value = { ...data.loginPolicy, ...normalized }
      domains.value = normalized.allowed_email_domains.join(', ')
    })
  }

  const dirty = computed(() => {
    const base = savedSettings.value
    if (!base) return false
    const currentPolicy = normalizeLoginPolicy(policy.value)
    const currentDomains = parseAllowedDomains(domains.value)
    return (
      displayName.value !== base.displayName ||
      guests.value !== base.allowExternalGuests ||
      currentPolicy.allow_email_otp !== base.loginPolicy.allow_email_otp ||
      currentPolicy.allow_member_credential_change !== base.loginPolicy.allow_member_credential_change ||
      currentPolicy.require_sso_for_members !== base.loginPolicy.require_sso_for_members ||
      currentPolicy.allow_invite_links !== base.loginPolicy.allow_invite_links ||
      currentDomains.join(',') !== base.loginPolicy.allowed_email_domains.join(',')
    )
  })

  return {
    displayName,
    guests,
    policy,
    domains,
    dirty,
    commitSaved,
    initialize(key: string, data: PodAdminSettingsResponse) {
      if (source.value === key) return
      batch(() => {
        source.value = key
        commitSaved(data)
      })
    },
    section: signal('general'),
    precreateOpen,
    memberName,
    memberEmail,
    membership,
    resetMemberDraft() {
      batch(() => {
        memberName.value = ''
        memberEmail.value = ''
        membership.value = 'member'
        precreateOpen.value = false
      })
    },
    confirmUnbindCredential: signal<ConfirmUnbindMemberCredential | undefined>(),
    selectedUID: signal(''),
    memberAction: signal<'suspended' | 'offboarded' | 'restore'>('suspended'),
    reason: signal(''),
    identityVerified: signal(false),
    invitationEmail,
    invitationRole,
    expiryPreset,
    expiresAt,
    maxUses,
    maxUsesCustomized,
    setInvitationEmail(value: string) {
      batch(() => {
        const prevHadEmail = invitationEmail.value.trim().length > 0
        const nextHasEmail = value.trim().length > 0
        invitationEmail.value = value
        if (!maxUsesCustomized.value && prevHadEmail !== nextHasEmail) {
          maxUses.value = nextHasEmail ? '1' : ''
        }
      })
    },
    setMaxUses(value: string) {
      batch(() => {
        maxUsesCustomized.value = true
        maxUses.value = value
      })
    },
    resetInvitationDraft() {
      batch(() => {
        invitationEmail.value = ''
        invitationRole.value = 'member'
        expiryPreset.value = '7d'
        expiresAt.value = defaultLocalExpiry()
        maxUses.value = ''
        maxUsesCustomized.value = false
      })
    },
    adapterID,
    editingProviderID,
    providerID,
    enabled,
    config,
    preservedSecrets,
    closeProviderEditor() {
      batch(() => {
        adapterID.value = ''
        editingProviderID.value = undefined
        providerID.value = ''
        enabled.value = true
        config.value = {}
        preservedSecrets.value = []
      })
    }
  }
})
