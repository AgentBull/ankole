import { expect, test } from 'bun:test'
import type { PodAdminSettingsResponse } from '../api/generated/types.gen'
import { conversationSearchQuery, podKeys } from '../api'
import { podRouteTitle } from '../app'
import { routeSidebarTab } from '../sidebar'
import { AccountSettingsModel } from './account-settings'
import {
  PodSettingsModel,
  formatPermissionCondition,
  parseAllowedDomains,
  resolveInvitationExpiryISO
} from './pod-settings'

test('PodSettingsModel tracks dirty state across normalized loginPolicy and domain edits', () => {
  const model = new PodSettingsModel()
  expect(model.dirty.value).toBe(false)

  // Partial loginPolicy mocks (such as host-extensions) normalize cleanly without becoming dirty.
  model.initialize('pod-1', {
    displayName: 'Acme Space',
    allowExternalGuests: false,
    emailAvailable: true,
    loginPolicy: {
      allowed_email_domains: ['Example.COM', ' sub.example.com '],
      allow_email_otp: true
    } as PodAdminSettingsResponse['loginPolicy']
  })
  expect(model.dirty.value).toBe(false)
  expect(model.domains.value).toBe('example.com, sub.example.com')

  // Whitespace and casing changes that produce the same domain list stay clean.
  model.domains.value = ' EXAMPLE.COM , sub.example.com '
  expect(model.dirty.value).toBe(false)

  model.domains.value = 'example.com, new.org'
  expect(model.dirty.value).toBe(true)
  expect(parseAllowedDomains(model.domains.value)).toEqual(['example.com', 'new.org'])

  model.commitSaved({
    displayName: 'Acme Space',
    allowExternalGuests: false,
    loginPolicy: {
      ...model.policy.value,
      allowed_email_domains: parseAllowedDomains(model.domains.value)
    }
  })
  expect(model.dirty.value).toBe(false)

  model.policy.value = { ...model.policy.value, require_sso_for_members: true }
  expect(model.dirty.value).toBe(true)
})

test('invitation maxUses defaults to unlimited for links and 1 for email invites unless customized', () => {
  const model = new PodSettingsModel()
  expect(model.expiryPreset.value).toBe('7d')
  expect(model.maxUses.value).toBe('')

  model.setInvitationEmail('alice@example.com')
  expect(model.maxUses.value).toBe('1')

  model.setInvitationEmail('bob@example.com')
  expect(model.maxUses.value).toBe('1')

  model.setInvitationEmail('')
  expect(model.maxUses.value).toBe('')

  model.setMaxUses('5')
  model.setInvitationEmail('carol@example.com')
  expect(model.maxUses.value).toBe('5')

  model.resetInvitationDraft()
  expect(model.invitationEmail.value).toBe('')
  expect(model.maxUses.value).toBe('')
  expect(model.maxUsesCustomized.value).toBe(false)
})

test('resolveInvitationExpiryISO computes preset offsets and custom timestamps', () => {
  const base = Date.UTC(2026, 9, 27, 0, 0, 0)
  expect(resolveInvitationExpiryISO('24h', '', base)).toBe('2026-10-28T00:00:00.000Z')
  expect(resolveInvitationExpiryISO('7d', '', base)).toBe('2026-11-03T00:00:00.000Z')
  expect(resolveInvitationExpiryISO('30d', '', base)).toBe('2026-11-26T00:00:00.000Z')
  expect(resolveInvitationExpiryISO('custom', '2026-12-01T12:30', base)).toBe(
    new Date('2026-12-01T12:30').toISOString()
  )
})

test('formatPermissionCondition omits trivial conditions and strips JSON quotes from CEL strings', () => {
  expect(formatPermissionCondition(null)).toBeUndefined()
  expect(formatPermissionCondition(undefined)).toBeUndefined()
  expect(formatPermissionCondition(true)).toBeUndefined()
  expect(formatPermissionCondition('')).toBeUndefined()
  expect(formatPermissionCondition('  true  ')).toBeUndefined()
  expect(formatPermissionCondition({})).toBeUndefined()
  expect(formatPermissionCondition('principal.department == "eng"')).toBe('principal.department == "eng"')
})

test('provider and member draft helpers reset transient editor state cleanly', () => {
  const model = new PodSettingsModel()
  model.precreateOpen.value = true
  model.memberName.value = 'Alice'
  model.memberEmail.value = 'alice@example.com'
  model.membership.value = 'guest'
  model.resetMemberDraft()
  expect(model.precreateOpen.peek()).toBe(false)
  expect(model.memberName.peek()).toBe('')
  expect(model.memberEmail.peek()).toBe('')
  expect(model.membership.peek()).toBe('member')

  model.adapterID.value = 'lark'
  model.editingProviderID.value = 'lark'
  model.providerID.value = 'lark'
  model.config.value = { app_id: 'cli_1' }
  model.preservedSecrets.value = ['app_secret']
  model.closeProviderEditor()
  expect(model.adapterID.value).toBe('')
  expect(model.editingProviderID.value).toBeUndefined()
  expect(model.providerID.value).toBe('')
  expect(model.config.value).toEqual({})
  expect(model.preservedSecrets.value).toEqual([])
})

test('AccountSettingsModel stores challengeID across OTP resend attempts', () => {
  const account = new AccountSettingsModel()
  expect(account.challengeID.value).toBeUndefined()
  account.challengeID.value = 'ch-1'
  expect(account.challengeID.value).toBe('ch-1')
})

test('routeSidebarTab and podRouteTitle preserve sidebar context and format route titles', () => {
  expect(routeSidebarTab('/pages/abc')).toBe('home')
  expect(routeSidebarTab('/content/space')).toBe('home')
  expect(routeSidebarTab('/')).toBe('chat')
  expect(routeSidebarTab('/conversations/abc')).toBe('chat')
  expect(routeSidebarTab('/me')).toBeUndefined()
  expect(routeSidebarTab('/settings')).toBeUndefined()

  const t = (key: string) => key
  expect(podRouteTitle('/pages/abc', t)).toBeUndefined()
  expect(podRouteTitle('/me', t)).toBe('pod.account.title · Ankole')
  expect(podRouteTitle('/settings', t)).toBe('pod.settings.title · Ankole')
  expect(podRouteTitle('/', t)).toBe('pod.sidebar.tabs.chat · Ankole')
  expect(podRouteTitle('/conversations/abc', t, 'Design review')).toBe('Design review · Ankole')
  expect(podRouteTitle('/conversations/abc', t, '   ')).toBe('pod.sidebar.tabs.chat · Ankole')
  expect(podRouteTitle('/content/space', t)).toBe('pod.content.space · Ankole')
  expect(podRouteTitle('/content/search', t)).toBe('pod.content.search_pages · Ankole')
})

test('conversationSearchQuery keys empty queries with podKeys.conversations and scopes search queries', () => {
  expect(conversationSearchQuery('').queryKey).toEqual(podKeys.conversations)
  expect(conversationSearchQuery('  roadmap  ').queryKey).toEqual([...podKeys.conversations, 'search', 'roadmap'])
})
