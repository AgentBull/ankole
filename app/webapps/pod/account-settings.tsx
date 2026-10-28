import {
  Badge,
  Button,
  Card,
  CardHeader,
  CardContent,
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
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  podMe,
  updatePodProfile,
  reauthenticatePodMember,
  requestPodEmailBinding,
  verifyPodEmailBinding,
  unbindPodCredential,
  exitPod
} from './api/generated/sdk.gen'
import { AccountSettingsModel } from './state/account-settings'
import { replaceAuthentication } from '../common/browser-context'
import { ErrorBlock } from '../common/error-block'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'

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
      void client.invalidateQueries({ queryKey: ['pod-session'] })
    }
  })
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
  return (
    <div className="h-full overflow-y-auto">
      <div className="mx-auto grid w-full max-w-3xl content-start gap-6 px-6 pt-2 pb-10">
        <h1 className="text-2xl">{t('pod.account.title')}</h1>
        <ErrorBlock error={accountError} />
        {needsReauthentication && (
          <Button variant="outline" disabled={reauthenticate.isPending} onClick={() => reauthenticate.mutate()}>
            {t('pod.account.reauthenticate')}
          </Button>
        )}
        <Card>
          <CardHeader>
            <h2>{t('pod.account.profile')}</h2>
          </CardHeader>
          <CardContent>
            <form
              className="grid gap-3"
              onSubmit={event => {
                event.preventDefault()
                profile.mutate()
              }}>
              <Label htmlFor="profile-name">{t('auth.member_name')}</Label>
              <Input
                id="profile-name"
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
              <Button
                type="submit"
                disabled={
                  profile.isPending ||
                  !me.data ||
                  model.displayName.value === undefined ||
                  !model.displayName.value.trim() ||
                  model.displayName.value.trim() === me.data.displayName
                }>
                {t('common.save')}
              </Button>
              {profile.isSuccess && model.displayName.value === undefined && (
                <p role="status">{t('pod.settings.saved')}</p>
              )}
            </form>
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <h2>{t('pod.account.login_email')}</h2>
            <p>{t('auth.personal_email_notice')}</p>
          </CardHeader>
          <CardContent className="grid gap-4">
            {me.data?.credentials.map(credential => (
              <div key={credential.id} className="flex items-center justify-between gap-3">
                <div className="flex min-w-0 flex-wrap items-center gap-2">
                  <span className="break-all">{credential.identifier}</span>
                  {credential.provider !== 'email_otp' && (
                    <Badge variant="secondary">{humanizeTechnicalLabel(credential.provider)}</Badge>
                  )}
                </div>
                <Button
                  variant="outline"
                  disabled={!me.data.credentialChangeAllowed || me.data.credentials.length <= 1 || unbind.isPending}
                  onClick={() => {
                    unbind.reset()
                    model.confirmUnbind.value = credential.id
                  }}>
                  {t('pod.account.unbind')}
                </Button>
              </div>
            ))}
            {me.data && me.data.credentials.length <= 1 && (
              <p className="text-sm text-muted-foreground">{t('common.authn.last_login_method')}</p>
            )}
            {me.data?.credentialChangeAllowed ? (
              !model.challengeID.value ? (
                <form
                  className="grid gap-3"
                  onSubmit={event => {
                    event.preventDefault()
                    request.mutate(false)
                  }}>
                  <Label htmlFor="binding-email">{t('pod.account.new_email')}</Label>
                  <Input
                    id="binding-email"
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
                  <Button type="submit" variant="outline" disabled={request.isPending}>
                    {t('auth.send_code')}
                  </Button>
                </form>
              ) : (
                <form
                  className="grid gap-3"
                  onSubmit={event => {
                    event.preventDefault()
                    verify.mutate()
                  }}>
                  <p role="status" className="text-sm text-muted-foreground">
                    {t('auth.code_sent', { email: model.email.value })}
                  </p>
                  <Label htmlFor="binding-code">{t('auth.email_code')}</Label>
                  <Input
                    id="binding-code"
                    pattern="[0-9]{6}"
                    maxLength={6}
                    inputMode="numeric"
                    autoComplete="one-time-code"
                    required
                    autoFocus
                    disabled={verify.isPending || request.isPending}
                    value={model.code.value}
                    onChange={event => {
                      model.code.value = event.target.value
                      verify.reset()
                    }}
                  />
                  <Button
                    type="submit"
                    disabled={verify.isPending || request.isPending || model.code.value.length !== 6}>
                    {t('pod.account.bind_email')}
                  </Button>
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
              <p>{t('pod.account.credential_change_disabled')}</p>
            )}
          </CardContent>
        </Card>
        <Card>
          <CardHeader>
            <h2>{t('pod.account.exit')}</h2>
          </CardHeader>
          <CardContent>
            {me.data?.managed ? (
              <p>{t('pod.account.managed_exit')}</p>
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
          </CardContent>
        </Card>
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
            <ErrorBlock error={unbind.error} />
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
            <ErrorBlock error={exit.error} />
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
      </div>
    </div>
  )
}
