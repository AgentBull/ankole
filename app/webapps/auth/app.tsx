import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit/components/alert'
import { Button } from '@ankole/uikit/components/button'
import { Card, CardContent, CardHeader } from '@ankole/uikit/components/card'
import { Skeleton } from '@ankole/uikit/components/skeleton'
import { RiArrowRightSLine } from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { internalAPIGet } from '../common/internal-api-client'
import { requestErrorMessage } from '../common/request-errors'
import { ThemeToggle } from '../common/theme-toggle'
import { LocalPasswordForm } from './local-password-form'
import { PasswordChangeForm } from './password-change-form'
import { LoginModel } from './state/login-model'

type LoginProvider = {
  adapterID: string
  kind: 'password' | 'oidc'
  pluginID: string
  providerID: string
}

/**
 * Renders the admin sign-in SPA: a password form when the local provider is
 * enabled, OIDC provider buttons for the rest, and the first-sign-in password
 * change view.
 */
export function AuthApp() {
  'use no memo'

  useSignals()
  const model = useModel(LoginModel)
  const { t } = useTranslation()
  useEffect(() => {
    document.title = t('auth.document_title')
  }, [t])
  const providers = useQuery({
    queryKey: ['identity-providers'],
    queryFn: () => internalAPIGet<{ providers: LoginProvider[] }>('/.internal-apis/identity-providers')
  })
  const providerList = providers.data?.providers ?? []
  const hasPasswordProvider = providerList.some(provider => provider.kind === 'password')
  // The password provider must never render as an OIDC button: it has no
  // authorization URL, so the filter goes by kind rather than "everything".
  const ssoProviders = providerList.filter(provider => provider.kind === 'oidc')
  const changingPassword = model.view.value === 'change_password'

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
            <h1>{changingPassword ? t('auth.change_title') : t('auth.title')}</h1>
            <p>{changingPassword ? t('auth.change_description') : t('auth.description')}</p>
          </div>
        </CardHeader>
        <CardContent>
          {changingPassword ? (
            <PasswordChangeForm model={model} />
          ) : (
            <>
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
              {hasPasswordProvider ? <LocalPasswordForm model={model} /> : null}
              {hasPasswordProvider && ssoProviders.length > 0 ? (
                <div className="ak-login-divider" role="separator">
                  {t('auth.or_sso')}
                </div>
              ) : null}
              {ssoProviders.length > 0 ? (
                <div className="ak-login-list">
                  {ssoProviders.map(provider => (
                    <button
                      className="ak-login-provider"
                      key={provider.providerID}
                      type="button"
                      onClick={() => {
                        window.location.assign(oidcAuthorizationPath(provider.providerID))
                      }}>
                      <span>
                        <strong>
                          {t('auth.sign_in_with', { provider: humanizeTechnicalLabel(provider.adapterID) })}
                        </strong>
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
              ) : null}
              {!providers.error && !providers.isLoading && providerList.length === 0 ? (
                <p className="ak-muted">{t('auth.no_providers')}</p>
              ) : null}
              {providers.isLoading ? (
                <div className="grid gap-3" aria-label={t('common.loading')}>
                  <Skeleton className="h-16 w-full" />
                  <Skeleton className="h-16 w-full" />
                </div>
              ) : null}
            </>
          )}
        </CardContent>
      </Card>
    </main>
  )
}

function oidcAuthorizationPath(providerID: string): string {
  const pageQuery = new URLSearchParams(window.location.search)
  const returnTo = pageQuery.get('return_to') ?? '/console'
  const query = new URLSearchParams({ return_to: returnTo })

  if (pageQuery.get('oauth') === '1') query.set('oauth', '1')

  return `/sessions/oidc/${encodeURIComponent(providerID)}/authorization?${query}`
}
