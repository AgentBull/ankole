import {
  Badge,
  Button,
  buttonVariants,
  Dialog,
  DialogContent,
  DialogFooter,
  DialogTitle,
  Input,
  Label,
  toast
} from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import {
  RiArrowRightLine,
  RiLinksLine,
  RiLogoutBoxRLine,
  RiShieldKeyholeLine,
  RiUser3Line,
  RiComputerLine
} from '@remixicon/react'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { Link } from '@tanstack/react-router'
import { useTranslation } from 'react-i18next'
import {
  exitPod,
  podMe,
  reauthenticatePodMember,
  requestPodEmailBinding,
  unbindPodCredential,
  updatePodProfile,
  verifyPodEmailBinding
} from './api/generated/sdk.gen'
import type { PodMeResponse } from './api/generated/types.gen'
import { replaceAuthentication } from '../common/browser-context'
import { CodeSentStatus } from '../common/code-sent-status'
import { EmailOtpInput } from '../common/email-otp-input'
import { ContentError } from './content-primitives'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'
import { ProfileAvatarUpload } from './profile-avatar-upload'
import { refreshMemberProfileQueries } from './query-cache'
import { SettingsLayout, SettingsPanel, SettingsSection } from './settings-layout'
import { RunnerDevicesSettings } from './runner-devices'
import { AccountSettingsModel } from './state/account-settings'

export function AccountSettings() {
  useSignals()
  const { t } = useTranslation()
  const model = useModel(AccountSettingsModel)
  const client = useQueryClient()
  const reauthenticate = useMutation({
    mutationFn: () => reauthenticatePodMember(),
    onSuccess: ({ loginURL }) => window.location.assign(loginURL)
  })
  const me = useQuery({ queryKey: ['pod-me'], queryFn: () => podMe() })
  const refresh = async () => {
    const result = await me.refetch()
    if (result.error instanceof InternalAPIError && result.error.status === 401) {
      window.location.assign('/sessions/new?switch=1&return_to=/me')
    }
  }
  const profile = useMutation({
    mutationFn: () =>
      updatePodProfile({ body: { data: { displayName: model.displayName.value ?? me.data!.displayName } } }),
    onSuccess: async () => {
      await me.refetch()
      model.displayName.value = undefined
      void refreshMemberProfileQueries(client)
    }
  })
  const profileChanged =
    model.displayName.value !== undefined && model.displayName.value.trim() !== (me.data?.displayName ?? '')
  const request = useMutation({
    mutationFn: (_resend?: boolean) => requestPodEmailBinding({ body: { data: { email: model.email.value } } }),
    onSuccess: (data, resend) => {
      model.challengeID.value = data.challengeID
      model.code.value = ''
      verify.reset()
      if (resend) toast.success(t('auth.code_sent', { email: model.email.value }))
    }
  })
  const verify = useMutation({
    mutationFn: () =>
      verifyPodEmailBinding({ body: { data: { challengeID: model.challengeID.value!, code: model.code.value } } }),
    onSuccess: result => {
      replaceAuthentication(result.authenticationRef, result.csrfToken)
      void client.invalidateQueries({ queryKey: ['pod-session'] })
      request.reset()
      model.challengeID.value = undefined
      model.email.value = ''
      model.code.value = ''
      return refresh()
    }
  })
  const unbind = useMutation({
    mutationFn: (id: string) => unbindPodCredential({ path: { id } }),
    onSuccess: async () => {
      model.confirmUnbind.value = undefined
      await refresh()
    }
  })
  const exit = useMutation({
    mutationFn: () => exitPod(),
    onSuccess: () => window.location.assign('/sessions/logged-out')
  })
  const accountError =
    me.error ?? profile.error ?? reauthenticate.error ?? request.error ?? verify.error ?? unbind.error ?? exit.error
  const needsReauthentication = [request.error, verify.error, unbind.error, exit.error].some(
    error => requestErrorCode(error) === 'reauthentication_required'
  )
  const avatarUploaded = (avatarURL: string) => {
    client.setQueryData<PodMeResponse>(['pod-me'], current => (current ? { ...current, avatarURL } : current))
    void refreshMemberProfileQueries(client)
  }
  const navigation = [
    { value: 'profile', label: t('pod.account.profile'), icon: <RiUser3Line aria-hidden /> },
    { value: 'login', label: t('pod.account.login_methods'), icon: <RiShieldKeyholeLine aria-hidden /> },
    { value: 'connections', label: t('pod.connectors.title'), icon: <RiLinksLine aria-hidden /> },
    { value: 'devices', label: t('pod.runner.title'), icon: <RiComputerLine aria-hidden /> },
    { value: 'exit', label: t('pod.account.exit'), icon: <RiLogoutBoxRLine aria-hidden /> }
  ]

  return (
    <SettingsLayout
      title={t('pod.account.title')}
      description={t('pod.account.description')}
      navigationLabel={t('pod.account.navigation')}
      value={model.section.value}
      onValueChange={value => {
        model.section.value = value
      }}
      items={navigation}>
      <ContentError error={accountError} />
      {needsReauthentication && (
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-border bg-muted/30 px-4 py-3">
          <p className="text-sm text-muted-foreground">{t('pod.account.reauthenticate_hint')}</p>
          <Button
            variant="outline"
            size="sm"
            disabled={reauthenticate.isPending}
            onClick={() => reauthenticate.mutate()}>
            {t('pod.account.reauthenticate')}
          </Button>
        </div>
      )}
      <SettingsPanel value="profile">
        <SettingsSection title={t('pod.account.profile')} description={t('pod.account.profile_description')}>
          <div className="grid gap-6">
            <ProfileAvatarUpload
              kind="member"
              name={model.displayName.value ?? me.data?.displayName ?? ''}
              avatarURL={me.data?.avatarURL}
              onUploaded={avatarUploaded}
            />
            <form
              className="grid gap-4 border-t border-border pt-6"
              onSubmit={event => {
                event.preventDefault()
                profile.mutate()
              }}>
              <div className="grid max-w-md gap-2">
                <Label htmlFor="profile-name">{t('auth.member_name')}</Label>
                <Input
                  id="profile-name"
                  name="displayName"
                  required
                  maxLength={160}
                  disabled={profile.isPending}
                  autoComplete="name"
                  value={model.displayName.value ?? me.data?.displayName ?? ''}
                  onChange={event => {
                    profile.reset()
                    model.displayName.value = event.target.value
                  }}
                />
              </div>
              {/* Like the Space settings save bar, the save action appears only while there is a change. */}
              {(profileChanged || profile.isPending || profile.isSuccess) && (
                <div className="flex items-center justify-end gap-3">
                  {profile.isSuccess && model.displayName.value === undefined ? (
                    <p role="status" className="text-sm text-muted-foreground">
                      {t('pod.settings.saved')}
                    </p>
                  ) : (
                    <Button type="submit" disabled={profile.isPending || !me.data || !model.displayName.value?.trim()}>
                      {t('pod.settings.save_changes')}
                    </Button>
                  )}
                </div>
              )}
            </form>
          </div>
        </SettingsSection>
      </SettingsPanel>
      <SettingsPanel value="login">
        <SettingsSection title={t('pod.account.login_email')} description={t('auth.personal_email_notice')}>
          <div className="grid gap-5">
            <ul className="grid divide-y divide-border">
              {me.data?.credentials.map(credential => (
                <li
                  key={credential.id}
                  className="flex flex-wrap items-center justify-between gap-3 py-3 first:pt-0 last:pb-0">
                  <div className="flex min-w-0 flex-wrap items-center gap-2">
                    <span className="break-all text-sm">{credential.identifier}</span>
                    {credential.provider !== 'email_otp' && (
                      <Badge variant="secondary">{humanizeTechnicalLabel(credential.provider)}</Badge>
                    )}
                  </div>
                  <Button
                    variant="outline"
                    size="sm"
                    disabled={!me.data.credentialChangeAllowed || me.data.credentials.length <= 1 || unbind.isPending}
                    onClick={() => {
                      unbind.reset()
                      model.confirmUnbind.value = credential.id
                    }}>
                    {t('pod.account.unbind')}
                  </Button>
                </li>
              ))}
            </ul>
            {me.data && me.data.credentials.length <= 1 && (
              <p className="text-sm text-muted-foreground">{t('common.authn.last_login_method')}</p>
            )}
            {me.data?.credentialChangeAllowed ? (
              !model.challengeID.value ? (
                <form
                  className="grid max-w-md gap-3 border-t border-border pt-5"
                  onSubmit={event => {
                    event.preventDefault()
                    request.mutate(false)
                  }}>
                  <div className="grid gap-2">
                    <Label htmlFor="binding-email">{t('pod.account.new_email')}</Label>
                    <Input
                      id="binding-email"
                      name="email"
                      type="email"
                      autoComplete="email"
                      required
                      disabled={request.isPending}
                      value={model.email.value}
                      onChange={event => {
                        model.email.value = event.target.value
                        request.reset()
                        verify.reset()
                      }}
                    />
                  </div>
                  <div>
                    <Button type="submit" variant="outline" disabled={request.isPending}>
                      {t('auth.send_code')}
                    </Button>
                  </div>
                </form>
              ) : (
                <form
                  className="grid max-w-md gap-4 border-t border-border pt-5"
                  onSubmit={event => {
                    event.preventDefault()
                    if (verify.isPending || request.isPending || model.code.value.length !== 6) return
                    verify.mutate()
                  }}>
                  <CodeSentStatus email={model.email.value} />
                  <div className="grid gap-2">
                    <Label htmlFor="binding-code">{t('auth.email_code')}</Label>
                    <EmailOtpInput
                      id="binding-code"
                      disabled={verify.isPending || request.isPending}
                      value={model.code.value}
                      onChange={value => {
                        model.code.value = value
                        verify.reset()
                      }}
                    />
                  </div>
                  <div>
                    <Button
                      type="submit"
                      disabled={verify.isPending || request.isPending || model.code.value.length !== 6}>
                      {t('pod.account.bind_email')}
                    </Button>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Button
                      type="button"
                      variant="ghost"
                      disabled={request.isPending || verify.isPending}
                      onClick={() => request.mutate(true)}>
                      {t('auth.resend_code')}
                    </Button>
                    <Button
                      type="button"
                      variant="ghost"
                      disabled={request.isPending || verify.isPending}
                      onClick={() => {
                        request.reset()
                        verify.reset()
                        model.challengeID.value = undefined
                        model.code.value = ''
                      }}>
                      {t('auth.change_email')}
                    </Button>
                  </div>
                </form>
              )
            ) : (
              <p className="border-t border-border pt-5 text-sm text-muted-foreground">
                {t('pod.account.credential_change_disabled')}
              </p>
            )}
          </div>
        </SettingsSection>
      </SettingsPanel>
      <SettingsPanel value="connections">
        <SettingsSection title={t('pod.connectors.title')} description={t('pod.account.connectors_description')}>
          <Link to="/connectors" className={buttonVariants({ variant: 'outline', size: 'sm' })}>
            {t('pod.account.manage_connectors')}
            <RiArrowRightLine aria-hidden data-icon="inline-end" />
          </Link>
        </SettingsSection>
      </SettingsPanel>
      <SettingsPanel value="devices">
        <RunnerDevicesSettings />
      </SettingsPanel>
      <SettingsPanel value="exit">
        <SettingsSection
          title={t('pod.account.exit')}
          description={t('pod.account.exit_description')}
          className="ring-destructive/30">
          {me.data?.managed ? (
            <p className="text-sm leading-6 text-muted-foreground">{t('pod.account.managed_exit')}</p>
          ) : (
            <Button
              variant="destructive"
              onClick={() => {
                exit.reset()
                model.confirmExit.value = true
              }}>
              {t('pod.account.exit')}
            </Button>
          )}
        </SettingsSection>
      </SettingsPanel>
      <Dialog
        open={Boolean(model.confirmUnbind.value)}
        onOpenChange={open => {
          if (!open && !unbind.isPending) {
            unbind.reset()
            model.confirmUnbind.value = undefined
          }
        }}>
        <DialogContent>
          <DialogTitle>{t('pod.account.unbind')}</DialogTitle>
          <p>
            {t('pod.account.unbind_description', {
              email: me.data?.credentials.find(item => item.id === model.confirmUnbind.value)?.identifier
            })}
          </p>
          <ContentError error={unbind.error} />
          {requestErrorCode(unbind.error) === 'reauthentication_required' && (
            <Button disabled={reauthenticate.isPending} onClick={() => reauthenticate.mutate()}>
              {t('pod.account.reauthenticate')}
            </Button>
          )}
          <DialogFooter>
            <Button
              variant="outline"
              disabled={unbind.isPending}
              onClick={() => {
                unbind.reset()
                model.confirmUnbind.value = undefined
              }}>
              {t('common.cancel')}
            </Button>
            <Button
              variant="destructive"
              disabled={unbind.isPending}
              onClick={() => unbind.mutate(model.confirmUnbind.value!)}>
              {t('pod.account.unbind')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
      <Dialog
        open={model.confirmExit.value}
        onOpenChange={open => {
          if (!exit.isPending) {
            if (!open) exit.reset()
            model.confirmExit.value = open
          }
        }}>
        <DialogContent>
          <DialogTitle>{t('pod.account.exit')}</DialogTitle>
          <p>{t('pod.account.exit_description')}</p>
          <ContentError error={exit.error} />
          {requestErrorCode(exit.error) === 'reauthentication_required' && (
            <Button disabled={reauthenticate.isPending} onClick={() => reauthenticate.mutate()}>
              {t('pod.account.reauthenticate')}
            </Button>
          )}
          <DialogFooter>
            <Button
              variant="outline"
              disabled={exit.isPending}
              onClick={() => {
                exit.reset()
                model.confirmExit.value = false
              }}>
              {t('common.cancel')}
            </Button>
            <Button variant="destructive" disabled={exit.isPending} onClick={() => exit.mutate()}>
              {t('pod.account.confirm_exit')}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </SettingsLayout>
  )
}
