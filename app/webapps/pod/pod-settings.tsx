import {
  Badge,
  Button,
  Card,
  CardContent,
  CardHeader,
  Checkbox,
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  Input,
  Label,
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
  Skeleton,
  Tabs,
  TabsList,
  TabsTrigger,
  toast
} from '@ankole/uikit'
import { RiCheckLine, RiFileCopyLine } from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { browserSession } from '../common/api/generated/sdk.gen'
import { unusedProviderID } from '../common/identity-provider'
import { ConfigFields, defaultConfig, localizedText, setPath } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import { authenticationRef, podID, principalUID } from '../common/browser-context'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import * as api from './api/generated/sdk.gen'
import type { PodAdminMembersResponse, PodMemberAccessReviewResponse } from './api/generated/types.gen'
import { cachedPages, contentKeys, type PageDetail } from './content-api'
import {
  PodSettingsModel,
  formatPermissionCondition,
  parseAllowedDomains,
  resolveInvitationExpiryISO,
  type InvitationExpiryPreset
} from './state/pod-settings'
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
    if (settings.data) model.initialize(podID() ?? 'default', settings.data)
  }, [settings.data, model])
  const save = useMutation({
    mutationFn: () => {
      const payload = {
        displayName: model.displayName.value.trim(),
        allowExternalGuests: model.guests.value,
        loginPolicy: {
          ...model.policy.value,
          allowed_email_domains: parseAllowedDomains(model.domains.value)
        }
      }
      return api.updatePodAdminSettings({ body: { data: payload } }).then(() => payload)
    },
    onSuccess: payload => {
      model.commitSaved(payload)
      toast.success(t('pod.settings.saved'))
      void client.invalidateQueries({ queryKey: keys.settings })
      void client.invalidateQueries({ queryKey: ['pod-session'] })
    }
  })
  return (
    <form
      className="grid gap-5"
      onSubmit={event => {
        event.preventDefault()
        save.mutate()
      }}>
      <ErrorBlock error={settings.error ?? save.error} />
      <Card>
        <CardHeader>
          <h2>{t('pod.settings.space_profile', { defaultValue: 'Space profile' })}</h2>
        </CardHeader>
        <CardContent className="grid gap-4">
          <div className="grid gap-2">
            <Label htmlFor="space-name">{t('auth.space_name')}</Label>
            <Input
              id="space-name"
              required
              value={model.displayName.value}
              onChange={event => {
                save.reset()
                model.displayName.value = event.target.value
              }}
            />
          </div>
          <label className="flex items-center gap-3 text-sm">
            <Checkbox
              checked={model.guests.value}
              onCheckedChange={value => {
                save.reset()
                model.guests.value = value === true
              }}
            />
            <span>{t('pod.settings.allow_guests')}</span>
          </label>
        </CardContent>
      </Card>
      <Card>
        <CardHeader>
          <h2>{t('pod.settings.sign_in_policy', { defaultValue: 'Sign-in policy' })}</h2>
        </CardHeader>
        <CardContent className="grid gap-4">
          <div className="grid gap-2">
            <Label htmlFor="domains">{t('pod.settings.domains')}</Label>
            <Input
              id="domains"
              value={model.domains.value}
              onChange={event => {
                save.reset()
                model.domains.value = event.target.value
              }}
            />
            <p className="text-xs text-muted-foreground">{t('pod.settings.domains_hint')}</p>
          </div>
          <div className="grid gap-3">
            {(
              [
                'allow_email_otp',
                'allow_member_credential_change',
                'require_sso_for_members',
                'allow_invite_links'
              ] as const
            ).map(key => (
              <label key={key} className="flex items-center gap-3 text-sm">
                <Checkbox
                  checked={model.policy.value[key] === true}
                  disabled={
                    !settings.data?.emailAvailable &&
                    ['allow_email_otp', 'allow_member_credential_change'].includes(key)
                  }
                  onCheckedChange={value => {
                    save.reset()
                    model.policy.value = { ...model.policy.value, [key]: value === true }
                  }}
                />
                <span>{t(`pod.settings.${key}`)}</span>
              </label>
            ))}
          </div>
          {settings.data && !settings.data.emailAvailable && (
            <p className="text-xs text-muted-foreground">{t('pod.settings.smtp_required')}</p>
          )}
        </CardContent>
      </Card>
      <div className="flex items-center gap-3">
        <Button
          type="submit"
          disabled={!model.dirty.value || !model.displayName.value.trim() || save.isPending || !settings.data}>
          {t('common.save')}
        </Button>
      </div>
    </form>
  )
}

function memberStatusLabel(status: string, t: ReturnType<typeof useTranslation>['t']): string {
  switch (status) {
    case 'active':
      return t('pod.settings.status_active', { defaultValue: 'Active' })
    case 'disabled':
      return t('pod.settings.status_disabled', { defaultValue: 'Disabled' })
    case 'suspended':
      return t('pod.settings.status_suspended', { defaultValue: 'Suspended' })
    case 'offboarded':
      return t('pod.settings.status_offboarded', { defaultValue: 'Offboarded' })
    default:
      return humanizeTechnicalLabel(status)
  }
}

function Members({ model }: { model: Model }) {
  useSignals()
  const { t } = useTranslation()
  const client = useQueryClient()
  const session = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: ({ signal }) => browserSession({ signal }),
    staleTime: 60_000
  })
  const currentUID = session.data?.principalUID ?? principalUID()
  const members = useQuery({ queryKey: keys.members, queryFn: () => api.podAdminMembers() })
  const refresh = () => client.invalidateQueries({ queryKey: keys.members })
  const create = useMutation({
    mutationFn: () =>
      api.createPodMember({
        body: {
          data: {
            displayName: model.memberName.value,
            email: model.memberEmail.value,
            membership: model.membership.value
          }
        }
      }),
    onSuccess: () => {
      model.resetMemberDraft()
      toast.success(t('pod.settings.member_created', { defaultValue: 'Pending member created.' }))
      return refresh()
    }
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
    onSuccess: () => {
      model.confirmUnbindCredential.value = undefined
      return refresh()
    }
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
  const selectedMember = members.data?.members.find(item => item.uid === model.selectedUID.value)
  const pendingUnbind = model.confirmUnbindCredential.value
  return (
    <section className="grid gap-5">
      <ErrorBlock error={members.error ?? create.error ?? role.error ?? membership.error ?? unbind.error} />
      {!model.precreateOpen.value ? (
        <div className="flex">
          <Button
            variant="outline"
            onClick={() => {
              create.reset()
              model.precreateOpen.value = true
            }}>
            {t('pod.settings.precreate_member')}
          </Button>
        </div>
      ) : (
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
                  create.reset()
                  model.memberName.value = event.target.value
                }}
              />
              <Label htmlFor="member-email">{t('auth.email')}</Label>
              <Input
                id="member-email"
                type="email"
                required
                value={model.memberEmail.value}
                onChange={event => {
                  create.reset()
                  model.memberEmail.value = event.target.value
                }}
              />
              <RoleSelect
                value={model.membership.value}
                onChange={value => {
                  create.reset()
                  model.membership.value = value
                }}
              />
              <div className="flex flex-wrap gap-2">
                <Button type="submit" disabled={create.isPending}>
                  {t('pod.settings.precreate_member')}
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  disabled={create.isPending}
                  onClick={() => {
                    create.reset()
                    model.resetMemberDraft()
                  }}>
                  {t('common.cancel')}
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>
      )}
      {members.data?.members.map(member => {
        const isSelf = Boolean(currentUID && member.uid === currentUID)
        const statusText = memberStatusLabel(member.status, t)
        const metaLine = [member.email, t(`pod.settings.role_${member.membership}`)].filter(Boolean).join(' · ')
        return (
          <Card key={member.uid}>
            <CardHeader>
              <div className="flex flex-wrap items-center gap-2">
                <h2>{member.displayName}</h2>
                {member.administrator && (
                  <Badge variant="info">{t('pod.settings.role_admin', { defaultValue: 'Administrator' })}</Badge>
                )}
                <Badge variant={member.status === 'active' ? 'success' : 'secondary'}>{statusText}</Badge>
              </div>
              <p className="text-sm text-muted-foreground">{metaLine}</p>
            </CardHeader>
            <CardContent className="grid gap-3">
              <div className="flex flex-wrap gap-2">
                <Button
                  variant="outline"
                  disabled={role.isPending || member.membership === 'guest' || member.status !== 'active'}
                  onClick={() => role.mutate({ member, admin: !member.administrator })}>
                  {t(member.administrator ? 'pod.settings.remove_admin' : 'pod.settings.make_admin')}
                </Button>
                <Button
                  variant="outline"
                  disabled={membership.isPending || member.status !== 'active'}
                  onClick={() => membership.mutate(member)}>
                  {t(member.membership === 'guest' ? 'pod.settings.make_member' : 'pod.settings.make_guest')}
                </Button>
                <Button
                  variant="outline"
                  disabled={member.status !== 'active' || isSelf}
                  onClick={() => select(member, 'suspended')}>
                  {t('pod.settings.suspend')}
                </Button>
                <Button
                  variant="destructive"
                  disabled={member.status !== 'active' || isSelf}
                  onClick={() => select(member, 'offboarded')}>
                  {t('pod.settings.offboard')}
                </Button>
                {member.status !== 'active' && (
                  <Button variant="outline" onClick={() => select(member, 'restore')}>
                    {t('pod.settings.restore')}
                  </Button>
                )}
              </div>
              {member.credentials.map(credential => (
                <div key={credential.id} className="flex flex-wrap items-center justify-between gap-3">
                  <div className="flex min-w-0 flex-wrap items-center gap-2">
                    <span className="break-all">{credential.identifier}</span>
                    {credential.provider !== 'email_otp' && (
                      <Badge variant="secondary">{humanizeTechnicalLabel(credential.provider)}</Badge>
                    )}
                  </div>
                  <Button
                    variant="ghost"
                    disabled={unbind.isPending}
                    onClick={() => {
                      unbind.reset()
                      model.confirmUnbindCredential.value = {
                        uid: member.uid,
                        id: credential.id,
                        identifier: credential.identifier,
                        memberName: member.displayName
                      }
                    }}>
                    {t('pod.account.unbind')}
                  </Button>
                </div>
              ))}
            </CardContent>
          </Card>
        )
      })}
      <Dialog
        open={Boolean(pendingUnbind)}
        onOpenChange={open => {
          if (!open && !unbind.isPending) {
            unbind.reset()
            model.confirmUnbindCredential.value = undefined
          }
        }}>
        <DialogContent>
          <DialogTitle>{t('pod.account.unbind')}</DialogTitle>
          {pendingUnbind && (
            <p>
              {t('pod.settings.unbind_member_credential_description', {
                email: pendingUnbind.identifier,
                name: pendingUnbind.memberName,
                defaultValue: 'Remove {$email} as a sign-in method for {$name}?'
              })}
            </p>
          )}
          <ErrorBlock error={unbind.error} />
          <DialogFooter>
            <Button
              type="button"
              variant="outline"
              disabled={unbind.isPending}
              onClick={() => {
                unbind.reset()
                model.confirmUnbindCredential.value = undefined
              }}>
              {t('common.cancel')}
            </Button>
            <Button
              type="button"
              variant="destructive"
              disabled={unbind.isPending || !pendingUnbind}
              onClick={() => pendingUnbind && unbind.mutate({ uid: pendingUnbind.uid, id: pendingUnbind.id })}>
              {t('pod.account.unbind')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog
        open={Boolean(model.selectedUID.value)}
        onOpenChange={open => {
          if (!open && !change.isPending) {
            change.reset()
            model.selectedUID.value = ''
          }
        }}>
        <DialogContent>
          <DialogTitle>{t(`pod.settings.${model.memberAction.value}`)}</DialogTitle>
          {selectedMember && (
            <p className="text-sm font-medium">
              {[selectedMember.displayName, selectedMember.email].filter(Boolean).join(' · ')}
            </p>
          )}
          <p className="text-sm text-muted-foreground">{t(`pod.settings.${model.memberAction.value}_description`)}</p>
          <ErrorBlock error={change.error ?? review.error} />
          {model.memberAction.value === 'restore' &&
            (review.isPending ? (
              <div className="grid gap-2" aria-busy="true">
                <Skeleton className="h-4 w-40" />
                <Skeleton className="h-16 w-full" />
              </div>
            ) : (
              review.data && <PermissionReview review={review.data.review.permission_review} />
            ))}
          {model.memberAction.value === 'restore' && (
            <label className="flex items-start gap-3 text-sm">
              <Checkbox
                checked={model.identityVerified.value}
                onCheckedChange={value => {
                  model.identityVerified.value = value === true
                }}
              />
              <span>{t('pod.settings.identity_verified')}</span>
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
            <DialogFooter>
              <Button
                type="button"
                variant="outline"
                disabled={change.isPending}
                onClick={() => {
                  change.reset()
                  model.selectedUID.value = ''
                }}>
                {t('common.cancel')}
              </Button>
              <Button
                type="submit"
                variant={model.memberAction.value === 'offboarded' ? 'destructive' : 'default'}
                disabled={
                  change.isPending ||
                  (model.memberAction.value === 'restore' && (!model.identityVerified.value || !review.data))
                }>
                {t(`pod.settings.${model.memberAction.value}`)}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </section>
  )
}

const uuidInPattern = /([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})/i

function PermissionReview({ review }: { review: PodMemberAccessReviewResponse['review']['permission_review'] }) {
  const { t } = useTranslation()
  const client = useQueryClient()
  const { permissions } = review
  if (permissions.groups.length === 0 && permissions.grants.length === 0 && permissions.userset_grants.length === 0) {
    return null
  }
  const pagesByID = new Map(cachedPages(client).map(page => [page.id, page]))
  const pageLabel = (id: string) => {
    const cached = pagesByID.get(id) ?? client.getQueryData<PageDetail>(contentKeys.page(id))?.page
    if (cached) return cached.title?.trim() || t('pod.content.untitled')
    return t('pod.content.page', { value1: id.slice(0, 8) })
  }
  const actionLabel = (action: string) => {
    switch (action) {
      case 'page_view':
        return t('pod.content.can_view')
      case 'page_write_records':
        return t('pod.content.can_contribute')
      case 'page_edit':
        return t('pod.content.can_edit')
      case 'page_manage':
        return t('pod.content.full_access')
      default:
        return humanizeTechnicalLabel(action)
    }
  }
  const scopeLabel = (scope: string) => {
    switch (scope) {
      case 'container':
        return t('pod.content.sharing_scope_container')
      case 'self':
        return t('pod.content.sharing_scope_self')
      default:
        return humanizeTechnicalLabel(scope)
    }
  }
  const groupKindLabel = (kind: string) => {
    switch (kind) {
      case 'static':
        return t('console.principal_groups.kind_static')
      case 'computed':
        return t('console.principal_groups.kind_computed')
      default:
        return humanizeTechnicalLabel(kind)
    }
  }
  const resourceLabel = (pattern: string) => {
    if (pattern === 'pod:space:**' || pattern === 'pod:space:*') return t('pod.content.space')
    if (pattern === 'pod:private:**' || pattern === 'pod:private:*') return t('pod.content.private')
    if (pattern === 'site_console:**') return t('pod.sidebar.site_console')
    const pageMatch = uuidInPattern.exec(pattern)
    if (pageMatch) {
      const label = pageLabel(pageMatch[1]!)
      return pattern.endsWith(':**') ? `${label} (${t('pod.content.sharing_scope_container')})` : label
    }
    if (pattern.startsWith('agent:')) {
      return `${t('pod.content.agent_kind')} ${pattern.slice('agent:'.length, 'agent:'.length + 8)}`
    }
    return pattern
  }
  return (
    <details open className="grid gap-3 border border-border p-3 text-sm">
      <summary className="cursor-pointer font-medium">{t('pod.settings.permissions')}</summary>
      <p className="text-xs text-muted-foreground">{t('pod.settings.permissions_hint')}</p>
      {permissions.groups.map(group => {
        const condition = formatPermissionCondition(group.condition)
        return (
          <div key={group.id} className="grid gap-1">
            <div>
              <strong>{group.name}</strong> · {groupKindLabel(group.kind)}
            </div>
            {condition && <p className="font-mono text-xs text-muted-foreground break-all">{condition}</p>}
          </div>
        )
      })}
      {permissions.grants.map(grant => {
        const condition = formatPermissionCondition(grant.condition)
        return (
          <div key={grant.id} className="grid gap-1">
            <div>
              <span className="font-medium">{resourceLabel(grant.resource_pattern)}</span> ·{' '}
              <span>{actionLabel(grant.action)}</span>
            </div>
            {condition && <p className="font-mono text-xs text-muted-foreground break-all">{condition}</p>}
          </div>
        )
      })}
      {permissions.userset_grants.map(grant => {
        const condition = formatPermissionCondition(grant.condition)
        return (
          <div key={grant.id} className="grid gap-1">
            <div>
              {t('pod.settings.userset_grant_summary', {
                action: actionLabel(grant.action),
                target: pageLabel(grant.target_page_id),
                scope: scopeLabel(grant.target_scope),
                sourceAction: actionLabel(grant.source_action),
                source: pageLabel(grant.source_page_id),
                defaultValue: '{$action} on {$target} ({$scope}) when the member has {$sourceAction} on {$source}'
              })}
            </div>
            {condition && <p className="font-mono text-xs text-muted-foreground break-all">{condition}</p>}
          </div>
        )
      })}
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
  const [copiedURL, setCopiedURL] = useState<string>()
  const invitations = useQuery({ queryKey: keys.invitations, queryFn: () => api.podAdminInvitations() })
  const settings = useQuery({ queryKey: keys.settings, queryFn: () => api.podAdminSettings() })
  const refresh = () => client.invalidateQueries({ queryKey: keys.invitations })
  const create = useMutation({
    mutationFn: () =>
      api.createPodInvitation({
        body: {
          data: {
            email: model.invitationEmail.value.trim() || undefined,
            membership: model.invitationRole.value,
            expiresAt: resolveInvitationExpiryISO(model.expiryPreset.value, model.expiresAt.value),
            maxUses: model.maxUses.value ? Number(model.maxUses.value) : undefined
          }
        }
      }),
    onSuccess: () => {
      model.resetInvitationDraft()
      toast.success(t('pod.settings.invitation_created', { defaultValue: 'Invitation created.' }))
      return refresh()
    }
  })
  const revoke = useMutation({
    mutationFn: (id: string) => api.revokePodInvitation({ path: { id } }),
    onSuccess: refresh
  })
  const now = Date.now()
  return (
    <section className="grid gap-5">
      <ErrorBlock error={invitations.error ?? create.error ?? revoke.error} />
      <Card>
        <CardHeader>
          <h2>{t('pod.settings.create_invitation')}</h2>
        </CardHeader>
        <CardContent>
          <form
            className="grid gap-4"
            onSubmit={event => {
              event.preventDefault()
              create.mutate()
            }}>
            <div className="grid gap-2">
              <Label htmlFor="invite-email">{t('pod.settings.invitation_email')}</Label>
              <Input
                id="invite-email"
                type="email"
                disabled={!settings.data?.emailAvailable}
                value={model.invitationEmail.value}
                onChange={event => {
                  model.setInvitationEmail(event.target.value)
                }}
              />
              {settings.data && !settings.data.emailAvailable && (
                <p className="text-xs text-muted-foreground">{t('pod.settings.smtp_required')}</p>
              )}
            </div>
            <div className="grid gap-2">
              <Label>{t('pod.settings.membership')}</Label>
              <RoleSelect
                value={model.invitationRole.value}
                onChange={value => {
                  model.invitationRole.value = value
                }}
              />
            </div>
            <div className="grid gap-2">
              <Label htmlFor="invite-expiry-preset">{t('pod.settings.expires')}</Label>
              <Select
                value={model.expiryPreset.value}
                onValueChange={value => {
                  if (value) model.expiryPreset.value = value as InvitationExpiryPreset
                }}>
                <SelectTrigger id="invite-expiry-preset" aria-label={t('pod.settings.expires')}>
                  <SelectValue />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="24h">{t('pod.settings.expires_24h', { defaultValue: '24 hours' })}</SelectItem>
                  <SelectItem value="7d">{t('pod.settings.expires_7d', { defaultValue: '7 days' })}</SelectItem>
                  <SelectItem value="30d">{t('pod.settings.expires_30d', { defaultValue: '30 days' })}</SelectItem>
                  <SelectItem value="custom">
                    {t('pod.settings.expires_custom', { defaultValue: 'Custom date and time' })}
                  </SelectItem>
                </SelectContent>
              </Select>
              {model.expiryPreset.value === 'custom' && (
                <Input
                  id="invite-expiry"
                  type="datetime-local"
                  required
                  aria-label={t('pod.settings.expires')}
                  value={model.expiresAt.value}
                  onChange={event => {
                    model.expiresAt.value = event.target.value
                  }}
                />
              )}
            </div>
            <div className="grid gap-2">
              <Label htmlFor="invite-uses">{t('pod.settings.max_uses')}</Label>
              <Input
                id="invite-uses"
                type="number"
                min={1}
                value={model.maxUses.value}
                onChange={event => {
                  model.setMaxUses(event.target.value)
                }}
              />
            </div>
            <div className="flex">
              <Button type="submit" disabled={create.isPending}>
                {t('pod.settings.create_invitation')}
              </Button>
            </div>
          </form>
        </CardContent>
      </Card>
      {create.data && (
        <Card className="border-foreground/40 bg-muted/30">
          <CardHeader>
            <h2>{t('pod.settings.invitation_ready', { defaultValue: 'Invitation link ready' })}</h2>
          </CardHeader>
          <CardContent className="grid gap-3">
            <div className="flex min-w-0 flex-col gap-3 border border-border/70 bg-background p-3 sm:flex-row sm:items-center">
              <a
                href={create.data.url}
                className="min-w-0 flex-1 break-all font-mono text-sm underline underline-offset-4">
                {create.data.url}
              </a>
              <Button
                type="button"
                size="sm"
                variant="outline"
                onClick={() => {
                  const url = create.data!.url
                  void navigator.clipboard.writeText(url).then(
                    () => {
                      setCopiedURL(url)
                      toast.success(t('pod.settings.invitation_copied', { defaultValue: 'Invitation link copied.' }))
                    },
                    () => toast.error(t('pod.chat.copy_failed'))
                  )
                }}>
                {t('pod.settings.copy_invitation')}
                {copiedURL === create.data.url ? (
                  <RiCheckLine aria-hidden data-icon="inline-end" />
                ) : (
                  <RiFileCopyLine aria-hidden data-icon="inline-end" />
                )}
              </Button>
            </div>
          </CardContent>
        </Card>
      )}
      {invitations.data?.invitations.map(invitation => {
        const isRevoked = Boolean(invitation.revoked_at)
        const isExpired = !isRevoked && new Date(invitation.expires_at).getTime() <= now
        return (
          <Card key={invitation.id}>
            <CardContent className="flex flex-wrap items-center justify-between gap-4">
              <div className="flex min-w-0 flex-wrap items-center gap-2 text-sm">
                <span>
                  {invitation.invited_email || t('pod.settings.link_invitation')} ·{' '}
                  {t(`pod.settings.role_${invitation.membership}`)} · {invitation.used_count}/
                  {invitation.max_uses ?? '∞'} · {new Date(invitation.expires_at).toLocaleString()}
                </span>
                {isRevoked && <Badge variant="secondary">{t('pod.settings.revoked')}</Badge>}
                {isExpired && (
                  <Badge variant="secondary">{t('pod.settings.expired', { defaultValue: 'Expired' })}</Badge>
                )}
              </div>
              <Button
                variant="outline"
                disabled={isRevoked || isExpired || revoke.isPending}
                onClick={() => revoke.mutate(invitation.id)}>
                {t(isRevoked ? 'pod.settings.revoked' : 'pod.settings.revoke')}
              </Button>
            </CardContent>
          </Card>
        )
      })}
    </section>
  )
}

function Providers({ model }: { model: Model }) {
  useSignals()
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const [callbackCopied, setCallbackCopied] = useState(false)
  const [customizeCallback, setCustomizeCallback] = useState(false)
  const providers = useQuery({ queryKey: keys.providers, queryFn: () => api.podAdminIdentityProviders() })
  const adapters = providers.data?.adapters ?? []
  const adapter = adapters.find(item => item.adapter_id === model.adapterID.value)
  const save = useMutation({
    mutationFn: () =>
      (model.editingProviderID.value ? api.savePodIdentityProvider : api.createPodIdentityProvider)({
        path: { provider_id: model.providerID.value },
        body: {
          data: {
            adapter_id: model.adapterID.value,
            config: model.config.value,
            enabled: model.enabled.value
          }
        }
      }),
    onSuccess: () => {
      toast.success(t('pod.settings.saved'))
      setCustomizeCallback(false)
      model.closeProviderEditor()
      return client.invalidateQueries({ queryKey: keys.providers })
    }
  })
  const sync = useMutation({
    mutationFn: (provider_id: string) => api.syncPodDirectory({ path: { provider_id } }),
    onSuccess: () => toast.success(t('console.identity.sync_started'))
  })
  const selectAdapter = (value: string) => {
    const item = adapters.find(item => item.adapter_id === value)
    if (!item) return
    model.adapterID.value = value
    model.editingProviderID.value = undefined
    model.providerID.value = unusedProviderID(
      item.default_provider_id,
      providers.data?.providers.map(provider => provider.provider_id) ?? []
    )
    model.enabled.value = true
    setCallbackCopied(false)
    setCustomizeCallback(false)
    save.reset()
    model.config.value = defaultConfig(item.fields)
    model.preservedSecrets.value = []
  }
  const callbackURL = `${window.location.origin}/sessions/oidc/${encodeURIComponent(model.providerID.value)}/callback`
  const copyCallbackURL = () => {
    void navigator.clipboard.writeText(callbackURL).then(
      () => {
        setCallbackCopied(true)
        toast.success(t('setup.oidc_callback_url_copied'))
        window.setTimeout(() => setCallbackCopied(false), 2000)
      },
      () => toast.error(t('setup.oidc_callback_url_copy_failed'))
    )
  }
  return (
    <section className="grid gap-5">
      <ErrorBlock error={providers.error ?? save.error ?? sync.error} />
      {providers.data?.providers.map(provider => {
        const providerAdapter = adapters.find(item => item.adapter_id === provider.adapter_id)
        const displayName =
          (providerAdapter ? localizedText(providerAdapter.display_name, i18n.language) : undefined) ??
          humanizeTechnicalLabel(provider.adapter_id)
        const isEnabled = provider.enabled === true
        return (
          <Card key={provider.provider_id}>
            <CardContent className="flex flex-wrap items-center justify-between gap-3">
              <div className="flex min-w-0 flex-wrap items-center gap-2">
                <span className="font-medium">{displayName}</span>
                <Badge variant={isEnabled ? 'success' : 'secondary'}>
                  {isEnabled
                    ? t('console.identity.enabled')
                    : t('pod.settings.status_disabled', { defaultValue: 'Disabled' })}
                </Badge>
                {provider.provider_id !== providerAdapter?.default_provider_id && (
                  <span className="font-mono text-xs text-muted-foreground">{provider.provider_id}</span>
                )}
              </div>
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  variant="outline"
                  disabled={save.isPending}
                  onClick={() => {
                    model.adapterID.value = provider.adapter_id
                    model.editingProviderID.value = provider.provider_id
                    model.providerID.value = provider.provider_id
                    model.config.value = provider.config
                    model.enabled.value = provider.enabled === true
                    model.preservedSecrets.value = provider.stored_secret_paths
                    setCallbackCopied(false)
                    setCustomizeCallback(false)
                    save.reset()
                  }}>
                  {t('common.edit')}
                </Button>
                <Button
                  variant="outline"
                  disabled={sync.isPending || !isEnabled}
                  onClick={() => sync.mutate(provider.provider_id)}>
                  {t('pod.settings.sync_directory')}
                </Button>
              </div>
            </CardContent>
          </Card>
        )
      })}
      {!adapter && adapters.length > 0 && (
        <div className="flex">
          <Button variant="outline" disabled={save.isPending} onClick={() => selectAdapter(adapters[0]!.adapter_id)}>
            {t('console.identity.new')}
          </Button>
        </div>
      )}
      {adapter && (
        <Card>
          <CardHeader>
            <h2>
              {model.editingProviderID.value
                ? (localizedText(adapter.display_name, i18n.language) ?? humanizeTechnicalLabel(adapter.adapter_id))
                : t('console.identity.new')}
            </h2>
          </CardHeader>
          <CardContent className="grid gap-4">
            {!model.editingProviderID.value && adapters.length > 1 && (
              <div className="grid gap-2">
                <Label>{t('pod.settings.provider')}</Label>
                <Select
                  disabled={save.isPending}
                  value={model.adapterID.value}
                  onValueChange={value => {
                    if (value) selectAdapter(value)
                  }}>
                  <SelectTrigger aria-label={t('pod.settings.provider')}>
                    <SelectValue />
                  </SelectTrigger>
                  <SelectContent>
                    {adapters.map(item => (
                      <SelectItem key={item.adapter_id} value={item.adapter_id}>
                        {localizedText(item.display_name, i18n.language) ?? humanizeTechnicalLabel(item.adapter_id)}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
              </div>
            )}
            <form
              className="grid gap-4"
              onSubmit={event => {
                event.preventDefault()
                save.mutate()
              }}>
              <div className="grid gap-2">
                <p className="text-sm font-medium">{t('setup.oidc_callback_url')}</p>
                <div className="flex min-w-0 flex-col gap-3 border border-border/70 bg-muted/30 p-3 sm:flex-row sm:items-center">
                  <code className="min-w-0 flex-1 break-all font-mono text-sm">{callbackURL}</code>
                  <Button type="button" size="sm" variant="outline" onClick={copyCallbackURL}>
                    {callbackCopied ? t('setup.oidc_callback_url_copied') : t('setup.oidc_callback_url_copy')}
                    {callbackCopied ? (
                      <RiCheckLine aria-hidden data-icon="inline-end" />
                    ) : (
                      <RiFileCopyLine aria-hidden data-icon="inline-end" />
                    )}
                  </Button>
                </div>
              </div>
              <Collapsible className="grid gap-3" open={customizeCallback} onOpenChange={setCustomizeCallback}>
                <CollapsibleTrigger className="text-left text-sm text-muted-foreground underline underline-offset-4">
                  {t('setup.customize_callback_url')}
                </CollapsibleTrigger>
                <CollapsibleContent className="grid gap-2 pt-2">
                  <Label htmlFor="provider-id">{t('setup.provider_id')}</Label>
                  <Input
                    id="provider-id"
                    disabled={save.isPending}
                    required
                    readOnly={Boolean(model.editingProviderID.value)}
                    pattern={'[a-z][a-z0-9_\\-]*'}
                    value={model.providerID.value}
                    onChange={event => {
                      save.reset()
                      setCallbackCopied(false)
                      model.providerID.value = event.target.value
                    }}
                  />
                  <p className="text-xs text-muted-foreground">{t('setup.provider_id_hint')}</p>
                </CollapsibleContent>
              </Collapsible>
              <ConfigFields
                fields={adapter.fields}
                config={model.config.value}
                locale={i18n.language}
                preservedSecretPaths={model.preservedSecrets.value}
                preservedSecretPlaceholder={t('common.secret_saved_placeholder')}
                onChange={(path, value) => {
                  save.reset()
                  model.config.value = setPath(model.config.value, path, value)
                }}
              />
              <label className="flex items-center gap-3 text-sm">
                <Checkbox
                  checked={model.enabled.value}
                  onCheckedChange={value => {
                    save.reset()
                    model.enabled.value = value === true
                  }}
                />
                <span>{t('pod.settings.provider_enabled')}</span>
              </label>
              <div className="flex flex-wrap items-center gap-2">
                <Button type="submit" disabled={save.isPending}>
                  {t(model.editingProviderID.value ? 'common.save' : 'console.identity.new')}
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  disabled={save.isPending}
                  onClick={() => {
                    save.reset()
                    setCallbackCopied(false)
                    setCustomizeCallback(false)
                    model.closeProviderEditor()
                  }}>
                  {t('common.cancel')}
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>
      )}
    </section>
  )
}
