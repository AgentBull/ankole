import { Button, Card, CardHeader, CardContent, Dialog, DialogContent, DialogTitle, Input, Label } from '@ankole/uikit'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  podMe,
  reauthenticatePodMember,
  requestPodEmailBinding,
  verifyPodEmailBinding,
  unbindPodCredential,
  exitPod
} from './api/generated/sdk.gen'
import { AccountSettingsModel } from './state/account-settings'
import { replaceAuthentication } from '../common/browser-context'
import { ErrorBlock } from '../common/error-block'
import { InternalAPIError } from '../common/internal-api-client'

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
  const request = useMutation({
    mutationFn: () => requestPodEmailBinding({ body: { data: { email: model.email.value } } })
  })
  const verify = useMutation({
    mutationFn: () =>
      verifyPodEmailBinding({ body: { data: { challengeID: request.data!.challengeID, code: model.code.value } } }),
    onSuccess: result => {
      replaceAuthentication(result.authenticationRef, result.csrfToken)
      void client.invalidateQueries({ queryKey: ['pod-session'] })
      request.reset()
      model.email.value = ''
      model.code.value = ''
      return refresh()
    }
  })
  const unbind = useMutation({
    mutationFn: (id: string) => unbindPodCredential({ path: { id } }),
    onSuccess: refresh
  })
  const exit = useMutation({
    mutationFn: () => exitPod(),
    onSuccess: () => window.location.assign('/sessions/logged-out')
  })
  return (
    <main className="mx-auto w-full max-w-3xl overflow-auto p-6 grid gap-6 content-start">
      <h1 className="text-2xl">{t('pod.account.title')}</h1>
      <ErrorBlock
        error={me.error ?? reauthenticate.error ?? request.error ?? verify.error ?? unbind.error ?? exit.error}
      />
      <Button variant="outline" disabled={reauthenticate.isPending} onClick={() => reauthenticate.mutate()}>
        {t('pod.account.reauthenticate')}
      </Button>
      <Card>
        <CardHeader>
          <h2>{t('pod.account.login_email')}</h2>
          <p>{t('auth.personal_email_notice')}</p>
        </CardHeader>
        <CardContent className="grid gap-4">
          {me.data?.credentials.map(credential => (
            <div key={credential.id} className="flex items-center justify-between gap-3">
              <span>{credential.identifier}</span>
              <Button
                variant="outline"
                disabled={!me.data.credentialChangeAllowed || unbind.isPending}
                onClick={() => unbind.mutate(credential.id)}>
                {t('pod.account.unbind')}
              </Button>
            </div>
          ))}
          {me.data?.credentialChangeAllowed ? (
            <>
              <form
                className="grid gap-3"
                onSubmit={event => {
                  event.preventDefault()
                  request.mutate()
                }}>
                <Label htmlFor="binding-email">{t('pod.account.new_email')}</Label>
                <Input
                  id="binding-email"
                  type="email"
                  autoComplete="email"
                  required
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
              {request.data && (
                <form
                  className="grid gap-3"
                  onSubmit={event => {
                    event.preventDefault()
                    verify.mutate()
                  }}>
                  <Label htmlFor="binding-code">{t('auth.email_code')}</Label>
                  <Input
                    id="binding-code"
                    pattern="[0-9]{6}"
                    maxLength={6}
                    inputMode="numeric"
                    autoComplete="one-time-code"
                    required
                    value={model.code.value}
                    onChange={event => {
                      model.code.value = event.target.value
                    }}
                  />
                  <Button type="submit" disabled={verify.isPending}>
                    {t('pod.account.bind_email')}
                  </Button>
                </form>
              )}
            </>
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
                model.confirmExit.value = true
              }}>
              {t('pod.account.exit')}
            </Button>
          )}
        </CardContent>
      </Card>
      <Dialog
        open={model.confirmExit.value}
        onOpenChange={open => {
          if (!exit.isPending) model.confirmExit.value = open
        }}>
        <DialogContent>
          <DialogTitle>{t('pod.account.exit')}</DialogTitle>
          <p>{t('pod.account.exit_description')}</p>
          <ErrorBlock error={exit.error} />
          <Button variant="destructive" disabled={exit.isPending} onClick={() => exit.mutate()}>
            {t('pod.account.confirm_exit')}
          </Button>
        </DialogContent>
      </Dialog>
    </main>
  )
}
