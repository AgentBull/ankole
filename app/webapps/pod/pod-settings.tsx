import {
  Button,
  Card,
  CardContent,
  CardHeader,
  Checkbox,
  Dialog,
  DialogContent,
  DialogTitle,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Tabs,
  TabsList,
  TabsTrigger
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { ConfigFields, defaultConfig, localizedText, setPath } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import { podID } from '../common/browser-context'
import * as api from './api/generated/sdk.gen'
import type { PodAdminMembersResponse, PodMemberAccessReviewResponse } from './api/generated/types.gen'
import { PodSettingsModel } from './state/pod-settings'
import { SlotBoundary, SlotGate } from '../common/slots'
import { usePodSlots, podSettingsSections, type PodSettingsTabSlot } from './slots'

type Model = InstanceType<typeof PodSettingsModel>
type Member = PodAdminMembersResponse['members'][number]
const keys = {
  settings: ['pod-admin-settings'],
  members: ['pod-admin-members'],
  invitations: ['pod-admin-invitations'],
  providers: ['pod-admin-providers']
}

export function PodSettings() {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(PodSettingsModel)
  const tabs = usePodSlots().settingsTabs ?? []
  return (
    <main className="mx-auto w-full max-w-5xl overflow-auto p-6 grid gap-6 content-start">
      <h1 className="text-2xl">{t('pod.settings.title')}</h1>
      <Tabs
        value={model.section.value}
        onValueChange={value => {
          model.section.value = value
        }}>
        <TabsList>
          {podSettingsSections.map(section => (
            <TabsTrigger key={section} value={section}>
              {t(`pod.settings.${section}`)}
            </TabsTrigger>
          ))}
          {tabs.map(slot => (
            <ExtensionTabTrigger key={slot.id} slot={slot} />
          ))}
        </TabsList>
      </Tabs>
      {model.section.value === 'general' && <GeneralSettings model={model} />}
      {model.section.value === 'members' && <Members model={model} />}
      {model.section.value === 'invitations' && <Invitations model={model} />}
      {model.section.value === 'providers' && <Providers model={model} />}
      {tabs.map(slot => (
        <ExtensionTabPanel key={slot.id} slot={slot} model={model} />
      ))}
    </main>
  )
}

function ExtensionTabTrigger({ slot }: { slot: PodSettingsTabSlot }) {
  const { t } = useTranslation()
  return (
    <SlotGate slot={slot}>
      {visible => visible && <TabsTrigger value={slot.id}>{t(slot.labelKey)}</TabsTrigger>}
    </SlotGate>
  )
}

function ExtensionTabPanel({ slot, model }: { slot: PodSettingsTabSlot; model: Model }) {
  return <SlotGate slot={slot}>{visible => <SettingsTabPanel slot={slot} model={model} visible={visible} />}</SlotGate>
}

function SettingsTabPanel({ slot, model, visible }: { slot: PodSettingsTabSlot; model: Model; visible: boolean }) {
  useSignals()
  useEffect(() => {
    if (!visible && model.section.value === slot.id) model.section.value = 'general'
  }, [visible, model, slot.id])
  if (!visible) return null
  return model.section.value === slot.id ? (
    <SlotBoundary>
      <slot.Component />
    </SlotBoundary>
  ) : null
}

function GeneralSettings({ model }: { model: Model }) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const settings = useQuery({ queryKey: keys.settings, queryFn: () => api.podAdminSettings() })
  useEffect(() => {
    if (settings.data) model.initialize(podID()!, settings.data)
  }, [settings.data, model])
  const save = useMutation({
    mutationFn: () =>
      api.updatePodAdminSettings({
        body: {
          data: {
            displayName: model.displayName.value,
            allowExternalGuests: model.guests.value,
            loginPolicy: {
              ...model.policy.value,
              allowed_email_domains: model.domains.value
                .split(',')
                .map(item => item.trim().toLowerCase())
                .filter(Boolean)
            }
          }
        }
      }),
    onSuccess: () => client.invalidateQueries({ queryKey: keys.settings })
  })
  return (
    <Card>
      <CardContent>
        <form
          className="grid gap-5"
          onSubmit={event => {
            event.preventDefault()
            save.mutate()
          }}>
          <ErrorBlock error={settings.error ?? save.error} />
          <Label htmlFor="space-name">{t('auth.space_name')}</Label>
          <Input
            id="space-name"
            required
            value={model.displayName.value}
            onChange={event => {
              model.displayName.value = event.target.value
            }}
          />
          <label className="flex gap-3">
            <Checkbox
              checked={model.guests.value}
              onCheckedChange={value => {
                model.guests.value = value === true
              }}
            />
            {t('pod.settings.allow_guests')}
          </label>
          <Label htmlFor="domains">{t('pod.settings.domains')}</Label>
          <Input
            id="domains"
            value={model.domains.value}
            onChange={event => {
              model.domains.value = event.target.value
            }}
          />
          <p>{t('pod.settings.domains_hint')}</p>
          {(
            [
              'allow_email_otp',
              'allow_member_credential_change',
              'require_sso_for_members',
              'allow_invite_links'
            ] as const
          ).map(key => (
            <label key={key} className="flex gap-3">
              <Checkbox
                checked={model.policy.value[key] === true}
                disabled={
                  !settings.data?.emailAvailable && ['allow_email_otp', 'allow_member_credential_change'].includes(key)
                }
                onCheckedChange={value => {
                  model.policy.value = { ...model.policy.value, [key]: value === true }
                }}
              />
              {t(`pod.settings.${key}`)}
            </label>
          ))}
          {!settings.data?.emailAvailable && <p>{t('pod.settings.smtp_required')}</p>}
          <Button type="submit" disabled={save.isPending || !settings.data}>
            {t('common.save')}
          </Button>
          {save.isSuccess && <p role="status">{t('pod.settings.saved')}</p>}
        </form>
      </CardContent>
    </Card>
  )
}

function Members({ model }: { model: Model }) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const members = useQuery({ queryKey: keys.members, queryFn: () => api.podAdminMembers() })
  const refresh = () => client.invalidateQueries({ queryKey: keys.members })
  const create = useMutation({
    mutationFn: () =>
      api.createPodMember({
        body: {
          data: {
            displayName: model.memberName.value,
            email: model.memberEmail.value || undefined,
            membership: model.membership.value
          }
        }
      }),
    onSuccess: refresh
  })
  const role = useMutation({
    mutationFn: ({ member, admin }: { member: Member; admin: boolean }) =>
      api.setPodAdministrator({ path: { uid: member.uid }, body: { data: { administrator: admin } } }),
    onSuccess: refresh
  })
  const membership = useMutation({
    mutationFn: (member: Member) =>
      api.changePodMembership({
        path: { uid: member.uid },
        body: { data: { membership: member.membership === 'guest' ? 'member' : 'guest' } }
      }),
    onSuccess: refresh
  })
  const unbind = useMutation({
    mutationFn: ({ uid, id }: { uid: string; id: string }) =>
      api.unbindPodMemberCredential({ path: { uid, credential_id: id } }),
    onSuccess: refresh
  })
  const review = useQuery({
    queryKey: ['pod-member-review', model.selectedUID.value],
    queryFn: () => api.podMemberAccessReview({ path: { uid: model.selectedUID.value } }),
    enabled: model.memberAction.value === 'restore' && Boolean(model.selectedUID.value)
  })
  const change = useMutation({
    mutationFn: () =>
      model.memberAction.value === 'restore'
        ? api.restorePodMember({
            path: { uid: model.selectedUID.value },
            body: {
              data: {
                reviewFingerprint: review.data!.review.permission_review.fingerprint,
                identityVerified: model.identityVerified.value,
                reason: model.reason.value
              }
            }
          })
        : api.disablePodMember({
            path: { uid: model.selectedUID.value },
            body: {
              data: {
                disposition: model.memberAction.value,
                reason: model.reason.value
              }
            }
          }),
    onSuccess: () => {
      model.selectedUID.value = ''
      return refresh()
    }
  })
  const select = (member: Member, action: 'suspended' | 'offboarded' | 'restore') => {
    change.reset()
    model.reason.value = ''
    model.identityVerified.value = false
    model.memberAction.value = action
    model.selectedUID.value = member.uid
  }
  return (
    <section className="grid gap-5">
      <ErrorBlock error={members.error ?? create.error ?? role.error ?? membership.error ?? unbind.error} />
      <Card>
        <CardHeader>
          <h2>{t('pod.settings.precreate_member')}</h2>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-3"
            onSubmit={event => {
              event.preventDefault()
              create.mutate()
            }}>
            <Label htmlFor="member-name">{t('auth.member_name')}</Label>
            <Input
              id="member-name"
              required
              value={model.memberName.value}
              onChange={event => {
                model.memberName.value = event.target.value
              }}
            />
            <Label htmlFor="member-email">{t('auth.email')}</Label>
            <Input
              id="member-email"
              type="email"
              value={model.memberEmail.value}
              onChange={event => {
                model.memberEmail.value = event.target.value
              }}
            />
            <RoleSelect
              value={model.membership.value}
              onChange={value => {
                model.membership.value = value
              }}
            />
            <Button type="submit" disabled={create.isPending}>
              {t('pod.settings.precreate_member')}
            </Button>
          </form>
        </CardContent>
      </Card>
      {members.data?.members.map(member => (
        <Card key={member.uid}>
          <CardHeader>
            <h2>{member.displayName}</h2>
            <p>
              {member.email} · {t(`pod.settings.role_${member.membership}`)} · {member.status}
            </p>
          </CardHeader>
          <CardContent className="grid gap-3">
            <div className="flex flex-wrap gap-2">
              <Button
                variant="outline"
                disabled={role.isPending || member.membership === 'guest' || member.status !== 'active'}
                onClick={() => role.mutate({ member, admin: !member.administrator })}>
                {t(member.administrator ? 'pod.settings.remove_admin' : 'pod.settings.make_admin')}
              </Button>
              <Button variant="outline" disabled={membership.isPending} onClick={() => membership.mutate(member)}>
                {t(member.membership === 'guest' ? 'pod.settings.make_member' : 'pod.settings.make_guest')}
              </Button>
              <Button variant="outline" onClick={() => select(member, 'suspended')}>
                {t('pod.settings.suspend')}
              </Button>
              <Button variant="destructive" onClick={() => select(member, 'offboarded')}>
                {t('pod.settings.offboard')}
              </Button>
              {member.status !== 'active' && (
                <Button variant="outline" onClick={() => select(member, 'restore')}>
                  {t('pod.settings.restore')}
                </Button>
              )}
            </div>
            {member.credentials.map(credential => (
              <div key={credential.id} className="flex gap-3 items-center">
                <span>{credential.identifier}</span>
                <Button
                  variant="ghost"
                  disabled={unbind.isPending}
                  onClick={() => unbind.mutate({ uid: member.uid, id: credential.id })}>
                  {t('pod.account.unbind')}
                </Button>
              </div>
            ))}
          </CardContent>
        </Card>
      ))}
      <Dialog
        open={Boolean(model.selectedUID.value)}
        onOpenChange={open => {
          if (!open && !change.isPending) model.selectedUID.value = ''
        }}>
        <DialogContent>
          <DialogTitle>{t(`pod.settings.${model.memberAction.value}`)}</DialogTitle>
          <p>{t(`pod.settings.${model.memberAction.value}_description`)}</p>
          <ErrorBlock error={change.error ?? review.error} />
          {model.memberAction.value === 'restore' && review.data && (
            <PermissionReview review={review.data.review.permission_review} />
          )}
          {model.memberAction.value === 'restore' && (
            <label className="flex gap-3">
              <Checkbox
                checked={model.identityVerified.value}
                onCheckedChange={value => {
                  model.identityVerified.value = value === true
                }}
              />
              {t('pod.settings.identity_verified')}
            </label>
          )}
          <form
            className="grid gap-3"
            onSubmit={event => {
              event.preventDefault()
              change.mutate()
            }}>
            <Label htmlFor="access-reason">{t('pod.settings.reason')}</Label>
            <Input
              id="access-reason"
              required
              value={model.reason.value}
              onChange={event => {
                model.reason.value = event.target.value
              }}
            />
            <Button
              type="submit"
              disabled={
                change.isPending ||
                (model.memberAction.value === 'restore' && (!model.identityVerified.value || !review.data))
              }>
              {t(`pod.settings.${model.memberAction.value}`)}
            </Button>
          </form>
        </DialogContent>
      </Dialog>
    </section>
  )
}

function PermissionReview({ review }: { review: PodMemberAccessReviewResponse['review']['permission_review'] }) {
  const { t } = useTranslation()
  const { permissions } = review
  return (
    <details open className="grid gap-3 border border-border p-3">
      <summary>{t('pod.settings.permissions')}</summary>
      <p>{t('pod.settings.permissions_hint')}</p>
      {permissions.groups.map(group => (
        <div key={group.id}>
          <strong>{group.name}</strong> · {group.kind}
          {Boolean(group.condition) && (
            <pre className="whitespace-pre-wrap text-xs">{JSON.stringify(group.condition, null, 2)}</pre>
          )}
        </div>
      ))}
      {permissions.grants.map(grant => (
        <div key={grant.id}>
          <code>
            {grant.resource_pattern} · {grant.action}
          </code>
          {Boolean(grant.condition) && (
            <pre className="whitespace-pre-wrap text-xs">{JSON.stringify(grant.condition, null, 2)}</pre>
          )}
        </div>
      ))}
      {permissions.userset_grants.map(grant => (
        <div key={grant.id}>
          <code>
            {grant.source_page_id} · {grant.source_action} → {grant.target_page_id} · {grant.target_scope} ·{' '}
            {grant.action}
          </code>
          <pre className="whitespace-pre-wrap text-xs">{grant.resource_pattern}</pre>
          <pre className="whitespace-pre-wrap text-xs">{JSON.stringify(grant.condition, null, 2)}</pre>
        </div>
      ))}
    </details>
  )
}

function RoleSelect({ value, onChange }: { value: 'member' | 'guest'; onChange(value: 'member' | 'guest'): void }) {
  const { t } = useTranslation()
  return (
    <Select value={value} onValueChange={value => onChange(value as 'member' | 'guest')}>
      <SelectTrigger aria-label={t('pod.settings.membership')}>
        <SelectValue />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="member">{t('pod.settings.role_member')}</SelectItem>
        <SelectItem value="guest">{t('pod.settings.role_guest')}</SelectItem>
      </SelectContent>
    </Select>
  )
}

function Invitations({ model }: { model: Model }) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const invitations = useQuery({ queryKey: keys.invitations, queryFn: () => api.podAdminInvitations() })
  const settings = useQuery({ queryKey: keys.settings, queryFn: () => api.podAdminSettings() })
  const refresh = () => client.invalidateQueries({ queryKey: keys.invitations })
  const create = useMutation({
    mutationFn: () =>
      api.createPodInvitation({
        body: {
          data: {
            email: model.invitationEmail.value || undefined,
            membership: model.invitationRole.value,
            expiresAt: new Date(model.expiresAt.value).toISOString(),
            maxUses: model.maxUses.value ? Number(model.maxUses.value) : undefined
          }
        }
      }),
    onSuccess: refresh
  })
  const revoke = useMutation({
    mutationFn: (id: string) => api.revokePodInvitation({ path: { id } }),
    onSuccess: refresh
  })
  return (
    <section className="grid gap-5">
      <ErrorBlock error={invitations.error ?? create.error ?? revoke.error} />
      <form
        className="grid gap-4"
        onSubmit={event => {
          event.preventDefault()
          create.mutate()
        }}>
        <Label htmlFor="invite-email">{t('pod.settings.invitation_email')}</Label>
        <Input
          id="invite-email"
          type="email"
          disabled={!settings.data?.emailAvailable}
          value={model.invitationEmail.value}
          onChange={event => {
            model.invitationEmail.value = event.target.value
          }}
        />
        <RoleSelect
          value={model.invitationRole.value}
          onChange={value => {
            model.invitationRole.value = value
          }}
        />
        <Label htmlFor="invite-expiry">{t('pod.settings.expires')}</Label>
        <Input
          id="invite-expiry"
          type="datetime-local"
          required
          value={model.expiresAt.value}
          onChange={event => {
            model.expiresAt.value = event.target.value
          }}
        />
        <Label htmlFor="invite-uses">{t('pod.settings.max_uses')}</Label>
        <Input
          id="invite-uses"
          type="number"
          min={1}
          value={model.maxUses.value}
          onChange={event => {
            model.maxUses.value = event.target.value
          }}
        />
        <Button type="submit" disabled={create.isPending}>
          {t('pod.settings.create_invitation')}
        </Button>
      </form>
      {create.data && (
        <Card>
          <CardContent className="grid gap-3">
            <a href={create.data.url}>{create.data.url}</a>
            <p>{t('pod.settings.invitation_code', { code: create.data.code })}</p>
            <Button variant="outline" onClick={() => navigator.clipboard.writeText(create.data!.url)}>
              {t('pod.settings.copy_invitation')}
            </Button>
          </CardContent>
        </Card>
      )}
      {invitations.data?.invitations.map(invitation => (
        <Card key={invitation.id}>
          <CardContent className="flex justify-between gap-4">
            <span>
              {invitation.invited_email || t('pod.settings.link_invitation')} ·{' '}
              {t(`pod.settings.role_${invitation.membership}`)} · {invitation.used_count}/{invitation.max_uses ?? '∞'} ·{' '}
              {new Date(invitation.expires_at).toLocaleString()}
            </span>
            <Button
              variant="outline"
              disabled={Boolean(invitation.revoked_at) || revoke.isPending}
              onClick={() => revoke.mutate(invitation.id)}>
              {t(invitation.revoked_at ? 'pod.settings.revoked' : 'pod.settings.revoke')}
            </Button>
          </CardContent>
        </Card>
      ))}
    </section>
  )
}

function Providers({ model }: { model: Model }) {
  useSignals()
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const providers = useQuery({ queryKey: keys.providers, queryFn: () => api.podAdminIdentityProviders() })
  const adapters = providers.data?.adapters ?? []
  const adapter = adapters.find(item => item.adapter_id === model.adapterID.value)
  const save = useMutation({
    mutationFn: () =>
      api.savePodIdentityProvider({
        path: { provider_id: model.providerID.value },
        body: {
          data: {
            adapter_id: model.adapterID.value,
            config: model.config.value,
            enabled: model.enabled.value
          }
        }
      }),
    onSuccess: () => client.invalidateQueries({ queryKey: keys.providers })
  })
  const sync = useMutation({ mutationFn: (provider_id: string) => api.syncPodDirectory({ path: { provider_id } }) })
  const selectAdapter = (value: string) => {
    const item = adapters.find(item => item.adapter_id === value)!
    model.adapterID.value = value
    model.providerID.value = item.default_provider_id
    model.config.value = defaultConfig(item.fields)
    model.preservedSecrets.value = []
  }
  return (
    <section className="grid gap-5">
      <ErrorBlock error={providers.error ?? save.error ?? sync.error} />
      {providers.data?.providers.map(provider => (
        <div key={provider.provider_id} className="flex flex-wrap items-center gap-3">
          <span>
            {provider.provider_id} · {provider.adapter_id}
          </span>
          <Button
            variant="outline"
            onClick={() => {
              model.adapterID.value = provider.adapter_id
              model.providerID.value = provider.provider_id
              model.config.value = provider.config
              model.enabled.value = provider.enabled === true
              model.preservedSecrets.value = provider.stored_secret_paths
            }}>
            {t('common.edit')}
          </Button>
          <Button variant="outline" disabled={sync.isPending} onClick={() => sync.mutate(provider.provider_id)}>
            {t('pod.settings.sync_directory')}
          </Button>
        </div>
      ))}
      <Select value={model.adapterID.value} onValueChange={value => selectAdapter(String(value))}>
        <SelectTrigger aria-label={t('pod.settings.provider')}>
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {adapters.map(item => (
            <SelectItem key={item.adapter_id} value={item.adapter_id}>
              {localizedText(item.display_name, i18n.language)}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      {adapter && (
        <form
          className="grid gap-4"
          onSubmit={event => {
            event.preventDefault()
            save.mutate()
          }}>
          <Label htmlFor="provider-id">{t('setup.provider_id')}</Label>
          <Input
            id="provider-id"
            required
            pattern={'[a-z][a-z0-9_\\-]*'}
            value={model.providerID.value}
            onChange={event => {
              model.providerID.value = event.target.value
            }}
          />
          <p>{t('setup.oidc_callback_url')}</p>
          <code className="break-all">
            {window.location.origin}/sessions/oidc/{encodeURIComponent(model.providerID.value)}/callback
          </code>
          <ConfigFields
            fields={adapter.fields}
            config={model.config.value}
            locale={i18n.language}
            preservedSecretPaths={model.preservedSecrets.value}
            onChange={(path, value) => {
              model.config.value = setPath(model.config.value, path, value)
            }}
          />
          <label className="flex gap-3">
            <Checkbox
              checked={model.enabled.value}
              onCheckedChange={value => {
                model.enabled.value = value === true
              }}
            />
            {t('pod.settings.provider_enabled')}
          </label>
          <Button type="submit" disabled={save.isPending}>
            {t('common.save')}
          </Button>
          {save.isSuccess && <p role="status">{t('pod.settings.saved')}</p>}
        </form>
      )}
    </section>
  )
}
