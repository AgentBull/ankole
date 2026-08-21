import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit/components/alert'
import { Button } from '@ankole/uikit/components/button'
import { Card, CardContent, CardHeader } from '@ankole/uikit/components/card'
import { Skeleton } from '@ankole/uikit/components/skeleton'
import { RiArrowRightSLine } from '@remixicon/react'
import { useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { internalAPIGet } from '../common/internal-api-client'
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
          {providers.error ? (
            <Alert variant="destructive">
              <AlertTitle>{t('common.error')}</AlertTitle>
              <AlertDescription className="grid gap-3">
                <span>{t('auth.error_description')}</span>
                <span className="font-mono text-xs">{requestErrorMessage(providers.error)}</span>
                <Button
                  className="w-fit"
                  size="xs"
                  type="button"
                  variant="outline"
                  onClick={() => {
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
                key={provider.providerID}
                type="button"
                onClick={() => {
                  window.location.assign(oidcAuthorizationPath(provider.providerID))
                }}>
                <span>
                  <strong>{t('auth.sign_in_with', { provider: humanizeTechnicalLabel(provider.adapterID) })}</strong>
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

function oidcAuthorizationPath(providerID: string): string {
  const returnTo = new URLSearchParams(window.location.search).get('return_to') ?? '/console'
  const query = new URLSearchParams({ return_to: returnTo })

  return `/sessions/oidc/${encodeURIComponent(providerID)}/authorization?${query}`
}
