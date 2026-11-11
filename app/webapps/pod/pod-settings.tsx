import { useCopyFeedback } from '@ankole/uikit/hooks/use-copy-feedback'
import { formatDateTime } from '../common/date-time'
import { ConnectorConfigFields } from '../common/connector-config-fields'
import {
  Badge,
  Button,
  buttonVariants,
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
  TabsTrigger,
  toast
} from '@ankole/uikit'
import {
  ArrowRightRegular,
  BotRegular,
  CheckmarkRegular,
  CopyRegular,
  LinkMultipleRegular,
  PeopleTeamRegular,
  PuzzlePieceRegular,
  SendRegular,
  SettingsRegular,
  ShieldKeyholeRegular,
  WindowConsoleRegular
} from '@ankole/uikit/icons'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useId, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { browserSession } from '../common/api/generated/sdk.gen'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import { unusedProviderID } from '../common/identity-provider'
import { defaultConfig, localizedText, setPath } from '../common/config-fields'
import { executeEnvVarBatchImport, type EnvVarSaveInput, type ParsedDotEnvItem } from './env-vars-dotenv'
import { EnvVarsEditor } from './env-vars-editor'
import { ContentError } from './content-primitives'
import { authenticationRef, podID, principalUID, replacePrincipalUID } from '../common/browser-context'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { availableLocaleIDs, loadLocale, nativeLocaleLabel } from '../common/i18n'
import * as api from './api/generated/sdk.gen'
import { appletEnvKeys } from './applet-settings-state'
import { contentKeys } from './content-api'
import { refreshAgentQueries, refreshSpaceProfileQueries } from './query-cache'
import { PrincipalRename } from '../common/principal-rename'
import type {
  PodAdminAgentsResponse,
  PodAdminMembersResponse,
  PodAdminSettingsResponse
} from './api/generated/types.gen'
import {
  PodSettingsModel,
  parseAllowedDomains,
  resolveInvitationExpiryISO,
  type InvitationExpiryPreset
} from './state/pod-settings'
import { SlotBoundary, SlotGate } from '../common/slots'
import { Link } from '@tanstack/react-router'
import { usePodSlots, podSettingsSections, type PodSettingsTabSlot } from './slots'
import { ProfileAvatarUpload } from './profile-avatar-upload'
import { SettingsLayout, SettingsPanel, SettingsSection } from './settings-layout'

type Model = InstanceType<typeof PodSettingsModel>
type Member = PodAdminMembersResponse['members'][number]
const keys = {
  settings: ['pod-admin-settings'],
  members: ['pod-admin-members'],
  agents: ['pod-admin-agents'],
  invitations: ['pod-admin-invitations'],
  providers: ['pod-admin-providers'],
  environment: ['pod-admin-worker-envs']
}

const navigationIcons: Record<string, ReactNode> = {
  general: <SettingsRegular aria-hidden />,
  members: <PeopleTeamRegular aria-hidden />,
  agents: <BotRegular aria-hidden />,
  invitations: <SendRegular aria-hidden />,
  providers: <ShieldKeyholeRegular aria-hidden />,
  environment: <WindowConsoleRegular aria-hidden />,
  connectors: <LinkMultipleRegular aria-hidden />
}

export function PodSettings() {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(PodSettingsModel)
  const tabs = usePodSlots().settingsTabs ?? []
  const navigation = [
    ...podSettingsSections.map(section => ({
      value: section,
      label: t(`pod.settings.${section}`),
      icon: navigationIcons[section]
    })),
    { value: 'connectors', label: t('pod.connectors.title'), icon: navigationIcons.connectors }
  ]
  return (
    <SettingsLayout
      title={t('pod.settings.title')}
      description={t('pod.settings.description')}
      navigationLabel={t('pod.settings.navigation')}
      value={model.section.value}
      onValueChange={value => {
        model.section.value = value
      }}
      items={navigation}
      navigationExtras={tabs.map(slot => (
        <ExtensionNavigationTrigger key={slot.id} slot={slot} />
      ))}>
      <SettingsPanel value="general">
        <GeneralSettings model={model} />
      </SettingsPanel>
      <SettingsPanel value="members">
        <SettingsSection
          framed={false}
          title={t('pod.settings.members')}
          description={t('pod.settings.members_description')}>
          <Members model={model} />
        </SettingsSection>
      </SettingsPanel>
      <SettingsPanel value="agents">
        <SettingsSection framed={false} title={t('pod.settings.agents')} description={t('pod.settings.agents_hint')}>
          <ManagedAgents />
        </SettingsSection>
      </SettingsPanel>
      <SettingsPanel value="invitations">
        <SettingsSection
          framed={false}
          title={t('pod.settings.invitations')}
          description={t('pod.settings.invitations_description')}>
          <Invitations model={model} />
        </SettingsSection>
      </SettingsPanel>
      <SettingsPanel value="providers">
        <SettingsSection
          framed={false}
          title={t('pod.settings.providers')}
          description={t('pod.settings.providers_description')}>
          <Providers model={model} />
        </SettingsSection>
      </SettingsPanel>
      <SettingsPanel value="environment">
        <PodEnvironmentSettings />
      </SettingsPanel>
      <SettingsPanel value="connectors">
        <SettingsSection title={t('pod.connectors.title')} description={t('pod.settings.connectors_description')}>
          <Link to="/connectors" className={buttonVariants({ variant: 'outline', size: 'sm' })}>
            {t('pod.settings.manage_connectors')}
            <ArrowRightRegular aria-hidden data-icon="inline-end" />
          </Link>
        </SettingsSection>
      </SettingsPanel>
      {tabs.map(slot => (
        <ExtensionTabPanel key={slot.id} slot={slot} model={model} />
      ))}
    </SettingsLayout>
  )
}

function PodEnvironmentSettings() {
  const { t } = useTranslation()
  const client = useQueryClient()
  const envs = useQuery({
    queryKey: keys.environment,
    queryFn: () => api.podAdminWorkerEnvs()
  })

  const refresh = async () => {
    await Promise.all([
      client.invalidateQueries({ queryKey: keys.environment }),
      client.invalidateQueries({ predicate: query => appletEnvKeys.matchesAnyPage(query.queryKey) }),
      client.invalidateQueries({ queryKey: [...contentKeys.all, 'applet-routes'] })
    ])
  }

  const putWorkerEnv = (input: EnvVarSaveInput) =>
    api.putPodAdminWorkerEnv({
      path: { name: input.name },
      body: {
        data: {
          ...(input.value === undefined ? {} : { value: input.value }),
          secret: input.secret,
          description: input.description ?? null
        }
      }
    })

  const handleSave = async (input: EnvVarSaveInput) => {
    await putWorkerEnv(input)
    await refresh()
    toast.success(t('pod.env_vars.saved', { name: input.name }))
  }

  const handleImport = (entries: ParsedDotEnvItem[], secret: boolean) =>
    executeEnvVarBatchImport({
      entries,
      secret,
      putVar: putWorkerEnv,
      refresh,
      onAllSaved: saved => toast.success(t('pod.env_vars.imported_count', { count: saved.length }))
    })

  const handleDelete = async (name: string) => {
    const response = await api.deletePodAdminWorkerEnv({ path: { name } })
    await refresh()
    toast.success(
      t(response.worker_env.source === 'missing' ? 'pod.env_vars.deleted' : 'pod.env_vars.reset_done', { name })
    )
  }

  return (
    <SettingsSection title={t('pod.settings.environment')} description={t('pod.settings.environment_description')}>
      <EnvVarsEditor
        items={envs.data?.worker_envs ?? []}
        ownSource="tenant"
        isLoading={envs.isLoading}
        error={envs.error}
        canDecrypt
        onRetry={() => void envs.refetch()}
        onSave={handleSave}
        onImport={handleImport}
        onDelete={handleDelete}
        onDecrypt={async name => {
          const response = await api.decryptPodAdminWorkerEnv({ path: { name } })
          return response.decrypted_value.value
        }}
      />
    </SettingsSection>
  )
}

function RenameMember({ member }: { member: Member }) {
  const client = useQueryClient()
  const mutation = useMutation({
    mutationFn: (newUID: string) =>
      api.renamePodMember({ path: { uid: member.uid }, body: { data: { new_uid: newUID } } }),
    onSuccess: result => {
      if (principalUID() === member.uid) {
        replacePrincipalUID(result.uid)
        client.setQueryData<BrowserSessionResponse>(
          ['pod-session', authenticationRef() ?? '', podID() ?? ''],
          session => session && { ...session, principalUID: result.uid }
        )
      }
      return client.invalidateQueries()
    }
  })
  return <PrincipalRename uid={member.uid} mutation={mutation} />
}

function ManagedAgents() {
  const client = useQueryClient()
  const agents = useQuery({ queryKey: keys.agents, queryFn: () => api.podAdminAgents() })
  const refresh = () => refreshAgentQueries(client)
  return (
    <section className="grid gap-4">
      <ContentError error={agents.error} />
      {agents.data?.agents.map(agent => (
        <ManagedAgent key={agent.uid} agent={agent} onSuccess={refresh} />
      ))}
    </section>
  )
}

export function ManagedAgent({
  agent,
  onSuccess
}: {
  agent: PodAdminAgentsResponse['agents'][number]
  onSuccess: () => Promise<unknown>
}) {
  const { t } = useTranslation()
  const headingID = useId()
  const rename = useMutation({
    mutationFn: (newUID: string) =>
      api.renamePodAgent({ path: { uid: agent.uid }, body: { data: { new_uid: newUID } } }),
    onSuccess
  })
  const status = useMutation({
    mutationFn: () =>
      agent.status === 'active'
        ? api.disablePodAgent({ path: { uid: agent.uid } })
        : api.enablePodAgent({ path: { uid: agent.uid } }),
    onSuccess
  })
  return (
    <Card role="group" aria-labelledby={headingID} className="rounded-xl">
      <CardHeader>
        <div className="flex flex-wrap items-center gap-2">
          <h2 id={headingID}>{agent.displayName}</h2>
          <Badge variant={agent.status === 'active' ? 'success' : 'secondary'}>
            {t(`console.status.${agent.status}`)}
          </Badge>
        </div>
        <p className="text-sm wrap-anywhere text-muted-foreground">
          @{agent.uid} · {t('pod.settings.agent_owner', { uid: agent.ownerUID })}
        </p>
      </CardHeader>
      <CardContent className="grid gap-3">
        <ContentError error={status.error} />
        <div className="flex flex-wrap gap-2">
          <Button
            type="button"
            variant="outline"
            size="sm"
            aria-label={t(agent.status === 'active' ? 'pod.settings.disable_agent' : 'pod.settings.enable_agent', {
              name: agent.displayName
            })}
            disabled={status.isPending}
            onClick={() => status.mutate()}>
            {t(agent.status === 'active' ? 'common.disable' : 'common.enable')}
          </Button>
          <PrincipalRename uid={agent.uid} agent mutation={rename} />
        </div>
      </CardContent>
    </Card>
  )
}

function ExtensionNavigationTrigger({ slot }: { slot: PodSettingsTabSlot }) {
  const { t } = useTranslation()
  return (
    <SlotGate slot={slot}>
      {visible =>
        visible && (
          <TabsTrigger
            value={slot.id}
            className="min-h-9 shrink-0 justify-start gap-2.5 rounded-lg px-3 py-2 text-sm md:h-9 md:py-1.5">
            <PuzzlePieceRegular aria-hidden />
            <span>{t(slot.labelKey)}</span>
          </TabsTrigger>
        )
      }
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
  return (
    <SettingsPanel value={slot.id}>
      <SlotBoundary variant="panel" resetKeys={[slot.id]}>
        <slot.Component />
      </SlotBoundary>
    </SettingsPanel>
  )
}

function GeneralSettings({ model }: { model: Model }) {
  useSignals()
  const { t, i18n } = useTranslation()
  const client = useQueryClient()
  const settings = useQuery({ queryKey: keys.settings, queryFn: () => api.podAdminSettings() })
  useEffect(() => {
    if (settings.data) model.initialize(podID() ?? 'default', settings.data)
  }, [settings.data, model])
  const save = useMutation({
    mutationFn: () => {
      const payload = {
        displayName: model.displayName.value.trim(),
        defaultLocale: model.defaultLocale.value,
        allowExternalGuests: model.guests.value,
        loginPolicy: {
          ...model.policy.value,
          allowed_email_domains: parseAllowedDomains(model.domains.value)
        }
      }
      return api.updatePodAdminSettings({ body: { data: payload } }).then(() => payload)
    },
    onSuccess: async payload => {
      model.commitSaved(payload)
      if (i18n.language !== payload.defaultLocale) {
        await loadLocale(payload.defaultLocale)
        document.documentElement.lang = payload.defaultLocale
        await i18n.changeLanguage(payload.defaultLocale)
      }
      toast.success(i18n.t('pod.settings.saved'))
      void refreshSpaceProfileQueries(client)
    }
  })
  const avatarUploaded = (avatarURL: string) => {
    client.setQueryData<PodAdminSettingsResponse>(keys.settings, current =>
      current ? { ...current, avatarURL } : current
    )
    void refreshSpaceProfileQueries(client)
  }
  return (
    <form
      className="grid gap-7"
      onSubmit={event => {
        event.preventDefault()
        save.mutate()
      }}>
      <ContentError error={settings.error ?? save.error} />
      <SettingsSection
        title={t('pod.settings.space_profile')}
        description={t('pod.settings.space_profile_description')}>
        <div className="grid gap-6">
          <ProfileAvatarUpload
            kind="space"
            name={model.displayName.value}
            avatarURL={settings.data?.avatarURL}
            onUploaded={avatarUploaded}
          />
          <div className="grid max-w-md gap-2 border-t border-border pt-6">
            <Label htmlFor="space-name">{t('auth.space_name')}</Label>
            <Input
              id="space-name"
              name="displayName"
              required
              value={model.displayName.value}
              onChange={event => {
                save.reset()
                model.displayName.value = event.target.value
              }}
            />
          </div>
          <div className="grid max-w-md gap-2">
            <Label htmlFor="space-default-locale">{t('pod.settings.default_locale')}</Label>
            <Select
              value={model.defaultLocale.value}
              onValueChange={locale => {
                if (!locale) return
                save.reset()
                model.defaultLocale.value = locale
              }}>
              <SelectTrigger id="space-default-locale" className="w-full">
                <SelectValue />
              </SelectTrigger>
              <SelectContent>
                {availableLocaleIDs().map(locale => (
                  <SelectItem key={locale} value={locale}>
                    {nativeLocaleLabel(locale)}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
            <p id="space-default-locale-hint" className="text-xs leading-5 text-muted-foreground">
              {t('pod.settings.default_locale_hint')}
            </p>
          </div>
          <label className="flex items-start gap-3 text-sm">
            <Checkbox
              checked={model.guests.value}
              onCheckedChange={value => {
                save.reset()
                model.guests.value = value === true
              }}
            />
            <span className="grid gap-1">
              <span>{t('pod.settings.allow_guests')}</span>
              <span className="text-xs leading-5 text-pretty text-muted-foreground">
                {t('pod.settings.allow_guests_hint')}
              </span>
            </span>
          </label>
        </div>
      </SettingsSection>
      <SettingsSection
        title={t('pod.settings.sign_in_policy')}
        description={t('pod.settings.sign_in_policy_description')}>
        <div className="grid gap-5">
          <div className="grid max-w-md gap-2">
            <Label htmlFor="domains">{t('pod.settings.domains')}</Label>
            <p id="domains-hint" className="text-xs leading-5 text-muted-foreground">
              {t('pod.settings.domains_hint')}
            </p>
            <Input
              id="domains"
              name="allowedEmailDomains"
              aria-describedby="domains-hint"
              value={model.domains.value}
              onChange={event => {
                save.reset()
                model.domains.value = event.target.value
              }}
            />
          </div>
          <div className="grid gap-3 border-t border-border pt-5">
            {(
              [
                'allow_email_otp',
                'allow_member_credential_change',
                'require_sso_for_members',
                'allow_invite_links'
              ] as const
            ).map(key => (
              <label key={key} className="flex min-h-8 items-center gap-3 text-sm">
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
            <p className="text-xs leading-5 text-muted-foreground">{t('pod.settings.smtp_required')}</p>
          )}
        </div>
      </SettingsSection>
      {(model.dirty.value || save.isPending) && (
        <div className="sticky bottom-3 z-10 flex items-center justify-between gap-3 rounded-xl border border-border bg-background/95 px-4 py-3 shadow-sm backdrop-blur">
          <p className="text-sm text-muted-foreground">{t('pod.settings.unsaved_changes')}</p>
          <Button type="submit" disabled={!model.displayName.value.trim() || save.isPending || !settings.data}>
            {t('pod.settings.save_changes')}
          </Button>
        </div>
      )}
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
  const change = useMutation({
    mutationFn: () =>
      model.memberAction.value === 'restore'
        ? api.restorePodMember({
            path: { uid: model.selectedUID.value },
            body: {
              data: {
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
    model.memberAction.value = action
    model.selectedUID.value = member.uid
  }
  const selectedMember = members.data?.members.find(item => item.uid === model.selectedUID.value)
  const pendingUnbind = model.confirmUnbindCredential.value
  return (
    <section className="grid gap-5">
      <ContentError error={members.error ?? create.error ?? role.error ?? membership.error ?? unbind.error} />
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
        <Card className="rounded-xl">
          <CardHeader>
            <h3 className="title-section">{t('pod.settings.precreate_member')}</h3>
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
          <Card className="rounded-xl" key={member.uid}>
            <CardHeader>
              <div className="flex flex-wrap items-center gap-2">
                <h3 className="title-section">{member.displayName}</h3>
                {member.administrator && (
                  <Badge variant="info">{t('pod.settings.role_admin', { defaultValue: 'Administrator' })}</Badge>
                )}
                <Badge variant={member.status === 'active' ? 'success' : 'secondary'}>{statusText}</Badge>
              </div>
              <p className="text-sm text-muted-foreground">{metaLine}</p>
            </CardHeader>
            <CardContent className="grid gap-3">
              <div className="flex flex-wrap gap-2">
                <RenameMember member={member} />
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
                  variant="outline"
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
              {member.credentials.length > 0 && (
                <p className="border-t border-border pt-3 text-xs font-medium text-muted-foreground">
                  {t('pod.account.login_methods')}
                </p>
              )}
              {member.credentials.map(credential => (
                <div key={credential.id} className="flex flex-wrap items-center justify-between gap-3">
                  <div className="flex min-w-0 flex-wrap items-center gap-2">
                    <span className="wrap-anywhere">{credential.identifier}</span>
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
          <ContentError error={unbind.error} />
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
          <ContentError error={change.error} />
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
                disabled={change.isPending}>
                {t(`pod.settings.${model.memberAction.value}`)}
              </Button>
            </DialogFooter>
          </form>
        </DialogContent>
      </Dialog>
    </section>
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
      <ContentError error={invitations.error ?? create.error ?? revoke.error} />
      <Card className="rounded-xl">
        <CardHeader>
          <h3 className="title-section">{t('pod.settings.create_invitation')}</h3>
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
            <h3 className="title-section">
              {t('pod.settings.invitation_ready', { defaultValue: 'Invitation link ready' })}
            </h3>
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
                  <CheckmarkRegular aria-hidden data-icon="inline-end" />
                ) : (
                  <CopyRegular aria-hidden data-icon="inline-end" />
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
          <Card className="rounded-xl" key={invitation.id}>
            <CardContent className="flex flex-wrap items-center justify-between gap-4">
              <div className="flex min-w-0 flex-wrap items-center gap-2 text-sm">
                <span>
                  {invitation.invited_email || t('pod.settings.link_invitation')} ·{' '}
                  {t(`pod.settings.role_${invitation.membership}`)} · {invitation.used_count}/
                  {invitation.max_uses ?? '∞'} · {formatDateTime(invitation.expires_at, undefined, 'medium')}
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
  const [callbackCopied, markCallbackCopied, resetCallbackCopied] = useCopyFeedback(false, 2000)
  const [customizeCallback, setCustomizeCallback] = useState(false)

  const providers = useQuery({ queryKey: keys.providers, queryFn: () => api.podAdminIdentityProviders() })
  const connectorCatalog = useQuery({
    queryKey: ['connectors', authenticationRef() ?? '', podID() ?? '', 'catalog'],
    queryFn: () => api.podConnectorsCatalog()
  })
  const connections = useQuery({
    queryKey: ['connectors', authenticationRef() ?? '', podID() ?? '', 'connections'],
    queryFn: () => api.podConnectorAuthConfigsList()
  })
  const adapters = providers.data?.adapters ?? []
  const editingProvider = providers.data?.providers.find(
    provider => provider.provider_id === model.editingProviderID.value
  )
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
    resetCallbackCopied()
    setCustomizeCallback(false)
    save.reset()
    model.config.value = defaultConfig(item.fields)
    model.preservedSecrets.value = []
  }
  const callbackURL = `${window.location.origin}/sessions/oidc/${encodeURIComponent(model.providerID.value)}/callback`
  const copyCallbackURL = () => {
    void navigator.clipboard.writeText(callbackURL).then(
      () => {
        markCallbackCopied(true)
        toast.success(t('setup.oidc_callback_url_copied'))
      },
      () => toast.error(t('setup.oidc_callback_url_copy_failed'))
    )
  }
  return (
    <section className="grid gap-5">
      <ContentError
        error={providers.error ?? connectorCatalog.error ?? connections.error ?? save.error ?? sync.error}
      />
      {providers.data?.providers.map(provider => {
        const providerAdapter = adapters.find(item => item.adapter_id === provider.adapter_id)
        const displayName =
          localizedText(provider.display_name, i18n.language) ??
          (providerAdapter ? localizedText(providerAdapter.display_name, i18n.language) : undefined) ??
          humanizeTechnicalLabel(provider.adapter_id)
        const isEnabled = provider.enabled === true
        return (
          <Card className="rounded-xl" key={provider.provider_id}>
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
                    resetCallbackCopied()
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
        <div
          className={
            providers.data?.providers.length === 0
              ? 'grid justify-items-center gap-3 rounded-lg border border-dashed border-border px-4 py-6 text-center'
              : 'flex'
          }>
          {providers.data?.providers.length === 0 && (
            <p className="text-sm text-muted-foreground">{t('pod.settings.providers_empty')}</p>
          )}
          <Button variant="outline" disabled={save.isPending} onClick={() => selectAdapter(adapters[0]!.adapter_id)}>
            {t('console.identity.new')}
          </Button>
        </div>
      )}
      {adapter && (
        <Card className="rounded-xl">
          <CardHeader>
            <h3 className="title-section">
              {model.editingProviderID.value
                ? (localizedText(editingProvider?.display_name, i18n.language) ??
                  localizedText(adapter.display_name, i18n.language) ??
                  humanizeTechnicalLabel(adapter.adapter_id))
                : t('console.identity.new')}
            </h3>
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
                      <CheckmarkRegular aria-hidden data-icon="inline-end" />
                    ) : (
                      <CopyRegular aria-hidden data-icon="inline-end" />
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
                      resetCallbackCopied()
                      model.providerID.value = event.target.value
                    }}
                  />
                  <p className="text-xs text-muted-foreground">{t('setup.provider_id_hint')}</p>
                </CollapsibleContent>
              </Collapsible>
              <ConnectorConfigFields
                pluginId={adapter.plugin_id ?? adapter.adapter_id}
                catalog={connectorCatalog.data?.connectors}
                connections={connections.data?.connections ?? []}
                onConnectionChange={config => {
                  save.reset()
                  model.config.value = config
                }}
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
                    resetCallbackCopied()
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
