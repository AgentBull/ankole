import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit/components/alert'
import { Button } from '@ankole/uikit/components/button'
import { Card, CardContent, CardHeader } from '@ankole/uikit/components/card'
import { Skeleton } from '@ankole/uikit/components/skeleton'
import { RiArrowRightSLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { internalAPIGet, internalAPIPost } from '../common/internal-api-client'
import { requestErrorMessage } from '../common/request-errors'
import { ThemeToggle } from '../common/theme-toggle'

type LoginProvider = {
  adapterID: string
  pluginID: string
  providerID: string
}

/** Renders the admin sign-in SPA and starts OIDC for the chosen provider. */
export function AuthApp() {
  const { t } = useTranslation()
  const providers = useQuery({
    queryKey: ['identity-providers'],
    queryFn: () => internalAPIGet<{ providers: LoginProvider[] }>('/.internal-apis/identity-providers')
  })
  const mutation = useMutation({
    mutationFn: (providerID: string) => {
      const returnTo = new URLSearchParams(window.location.search).get('return_to') ?? '/console'
      // The server validates and stores the OIDC state. The SPA only passes the
      // desired return path so the callback can land back in the correct screen.
      return internalAPIPost<{ authorizationURL: string }>(
        `/.internal-apis/identity-providers/${encodeURIComponent(providerID)}/oidc/authorizations?return_to=${encodeURIComponent(returnTo)}`
      )
    },
    onSuccess: result => window.location.assign(result.authorizationURL)
  })

  return (
    <main className="ak-auth-page relative">
      <ThemeToggle className="absolute top-4 right-4 border border-border bg-background/80 backdrop-blur" />
      <Card className="ak-auth-card">
        <CardHeader>
          <div className="ak-auth-heading">
            <div className="ak-auth-brand">
              <span aria-hidden>A</span>
              <p className="ak-eyebrow">Ankole</p>
            </div>
            <h1>{t('auth.title')}</h1>
            <p>{t('auth.description')}</p>
          </div>
        </CardHeader>
        <CardContent>
          {providers.error || mutation.error ? (
            <Alert variant="destructive">
              <AlertTitle>{t('common.error')}</AlertTitle>
              <AlertDescription className="grid gap-3">
                <span>{t('auth.error_description')}</span>
                <span className="font-mono text-xs">{requestErrorMessage(providers.error ?? mutation.error)}</span>
                <Button
                  className="w-fit"
                  size="xs"
                  type="button"
                  variant="outline"
                  onClick={() => {
                    mutation.reset()
                    void providers.refetch()
                  }}>
                  {t('common.retry')}
                </Button>
              </AlertDescription>
            </Alert>
          ) : null}
          <div className="ak-login-list">
            {(providers.data?.providers ?? []).map(provider => (
              <button
                className="ak-login-provider"
                disabled={mutation.isPending}
                key={provider.providerID}
                type="button"
                onClick={() => mutation.mutate(provider.providerID)}>
                <span>
                  <strong>{t('auth.sign_in_with', { provider: loginProviderLabel(provider.adapterID) })}</strong>
                  <small>
                    {t('auth.provider_details', {
                      providerID: provider.providerID,
                      adapterID: provider.adapterID,
                      pluginID: provider.pluginID
                    })}
                  </small>
                </span>
                <RiArrowRightSLine aria-hidden />
              </button>
            ))}
          </div>
          {!providers.error && !providers.isLoading && (providers.data?.providers ?? []).length === 0 ? (
            <p className="ak-muted">{t('auth.no_providers')}</p>
          ) : null}
          {providers.isLoading ? (
            <div className="grid gap-3" aria-label={t('common.loading')}>
              <Skeleton className="h-16 w-full" />
              <Skeleton className="h-16 w-full" />
            </div>
          ) : null}
        </CardContent>
      </Card>
    </main>
  )
}

function loginProviderLabel(adapterID: string): string {
  const initialisms = new Set(['id', 'ldap', 'oauth', 'oidc', 'sso'])
  return adapterID
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map(part =>
      initialisms.has(part.toLowerCase()) ? part.toUpperCase() : `${part[0]?.toUpperCase() ?? ''}${part.slice(1)}`
    )
    .join(' ')
}
