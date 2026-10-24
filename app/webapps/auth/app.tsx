import { Button, Card, CardContent, CardHeader, Skeleton } from '@ankole/uikit'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { loginProviders, selectLoginIdentity } from '../common/api/generated/sdk.gen'
import { localizedText } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import { ThemeToggle } from '../common/theme-toggle'
import { EmailOtpForm } from './email-otp-form'
import { InvitationJoin } from './invitation-join'
import { JoinSpaceForm } from './join-space-form'
import { SessionScreen } from './session-screen'

export function AuthApp() {
  const status = Number(document.querySelector<HTMLMetaElement>('meta[name="ankole-response-status"]')?.content ?? 200)
  if (window.location.pathname.startsWith('/join/')) return <InvitationJoin />
  if (window.location.pathname !== '/sessions/new' || status >= 400) return <SessionScreen invalid={status >= 400} />
  return <LoginApp />
}

function LoginApp() {
  const { t, i18n } = useTranslation()
  useEffect(() => {
    document.title = t('auth.document_title')
  }, [t])
  const flow = new URLSearchParams(window.location.search).get('flow') ?? ''
  const providers = useQuery({
    queryKey: ['identity-providers', flow],
    queryFn: () => loginProviders({ query: { flow } })
  })
  const selection = useMutation({
    mutationFn: (authenticationRef: string) => selectLoginIdentity({ body: { data: { flow, authenticationRef } } }),
    onSuccess: data => window.location.assign(data.returnTo)
  })
  const list = providers.data?.providers ?? []
  const hasEmail = list.some(provider => provider.providerID === 'email_otp')
  const sso = list.filter(provider => provider.kind === 'oidc')
  return (
    <main className="ak-auth-page relative">
      <ThemeToggle className="absolute top-4 right-4 border border-border bg-background/80 backdrop-blur" />
      <Card className="ak-auth-card">
        <CardHeader>
          <div className="ak-auth-heading">
            <p className="ak-eyebrow">Ankole</p>
            <h1>{t('auth.title')}</h1>
            <p>{t('auth.description')}</p>
          </div>
        </CardHeader>
        <CardContent className="grid gap-5">
          <ErrorBlock error={providers.error ?? selection.error} />
          {providers.data?.identities?.map(identity => (
            <Button
              key={`${identity.authenticationRef}:${identity.principalUID}`}
              variant="outline"
              disabled={selection.isPending}
              onClick={() => selection.mutate(identity.authenticationRef)}>
              {t('auth.continue_identity', { name: identity.displayName, provider: identity.providerID })}
            </Button>
          ))}
          {providers.data?.requireSSOForMembers && <p role="note">{t('auth.sso_required')}</p>}
          {hasEmail && <EmailOtpForm flow={flow} />}
          {sso.length > 0 && (
            <div className="ak-login-list">
              {sso.map(provider => (
                <Button
                  variant="outline"
                  key={provider.providerID}
                  onClick={() => {
                    const url = new URL(
                      `/sessions/oidc/${encodeURIComponent(provider.providerID)}/authorization`,
                      window.location.origin
                    )
                    url.searchParams.set('flow', flow)
                    window.location.assign(url)
                  }}>
                  {t('auth.sign_in_with', { provider: localizedText(provider.displayName, i18n.language) })}
                </Button>
              ))}
            </div>
          )}
          {providers.data?.purpose === 'site' && <JoinSpaceForm />}
          {providers.isLoading && <Skeleton className="h-16 w-full" aria-label={t('common.loading')} />}
          {!providers.error && !providers.isLoading && list.length === 0 && <p>{t('auth.no_providers')}</p>}
        </CardContent>
      </Card>
    </main>
  )
}
