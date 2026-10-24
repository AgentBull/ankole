import { Button } from '@ankole/uikit'
import { useMutation } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { activateBrowserAccount } from '../common/api/generated/sdk.gen'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
import { ErrorBlock } from '../common/error-block'

type Choice = { authenticationRef: string; tenant: { id: string } }

export function WorkspaceList({ session }: { session: BrowserSessionResponse }) {
  const { t } = useTranslation()
  const activate = useMutation({
    mutationFn: (choice: Choice) =>
      activateBrowserAccount({
        body: {
          data: {
            authenticationRef: choice.authenticationRef,
            tenantID: choice.tenant.id
          }
        }
      }),
    onSuccess: result => window.location.assign(result.podURL)
  })
  return (
    <div className="grid gap-3">
      <ErrorBlock error={activate.error} />
      {session.accounts.map(account => (
        <Button
          key={`${account.authenticationRef}:${account.tenant.id}`}
          variant="outline"
          disabled={activate.isPending}
          onClick={() => activate.mutate(account)}>
          {account.tenant.displayName} · {account.tenant.slug} · {account.displayName} ·{' '}
          {account.providerID === 'email_otp' ? t('auth.email_login') : account.providerID}
        </Button>
      ))}
      {session.pendingAccounts.map(account => (
        <Button
          key={`${account.authenticationRef}:${account.tenant.id}`}
          variant="outline"
          disabled={activate.isPending}
          onClick={() => activate.mutate(account)}>
          {t('auth.pending_space', { name: account.tenant.displayName })}
          {account.requiresSSO ? ` · ${t('auth.sso_required')}` : ''}
        </Button>
      ))}
    </div>
  )
}
