import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit/components/alert'
import { Button } from '@ankole/uikit/components/button'
import { Card, CardContent, CardHeader } from '@ankole/uikit/components/card'
import { Skeleton } from '@ankole/uikit/components/skeleton'
import { RiArrowRightSLine } from '@remixicon/react'
import { useModel } from '@preact/signals-react'
import { useSignals } from '@preact/signals-react/runtime'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useTranslation } from 'react-i18next'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { loginProviders, selectLoginIdentity } from '../common/api/generated/sdk.gen'
import { requestErrorMessage } from '../common/request-errors'
import { ThemeToggle } from '../common/theme-toggle'
import { LocalPasswordForm } from './local-password-form'
import { PasswordChangeForm } from './password-change-form'
import { SessionScreen } from './session-screen'
import { LoginModel } from './state/login-model'

/**
 * Renders the sign-in SPA: a password form when the local provider is
 * enabled, OIDC provider buttons for the rest, and the first-sign-in password
 * change view.
 */
export function AuthApp() {
  const status = Number(document.querySelector<HTMLMetaElement>('meta[name="ankole-response-status"]')?.content ?? 200)
  if (window.location.pathname !== '/sessions/new' || status >= 400) return <SessionScreen invalid={status >= 400} />
  return <LoginApp />
}

function LoginApp() {
  'use no memo'

  useSignals()
  const model = useModel(LoginModel)
  const { t } = useTranslation()
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
  const providerList = providers.data?.providers ?? []
  const hasPasswordProvider = providerList.some(provider => provider.kind === 'password')
  // The password provider must never render as an OIDC button: it has no
  // authorization URL, so the filter goes by kind rather than "everything".
  const ssoProviders = providerList.filter(provider => provider.kind === 'oidc' || provider.kind === 'site')
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
          {providers.data?.identity ? (
            <p className="mb-4 text-sm text-muted-foreground">
              {t('auth.current_identity', {
                name: providers.data.identity.displayName,
                provider: providers.data.identity.providerID
              })}
            </p>
          ) : null}
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
              {providers.data?.identities?.length ? (
                <div className="mb-5 grid gap-2">
                  <p>{t('auth.select_identity')}</p>
                  {providers.data.identities.map(identity => (
                    <Button
                      key={identity.authenticationRef}
                      type="button"
                      variant="outline"
                      disabled={selection.isPending}
                      onClick={() => selection.mutate(identity.authenticationRef)}>
                      {identity.displayName} · {identity.providerID}
                    </Button>
                  ))}
                  {selection.error ? <p role="alert">{requestErrorMessage(selection.error)}</p> : null}
                </div>
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
                        window.location.assign(
                          provider.loginPath
                            ? siteAuthorizationPath(provider.loginPath, flow)
                            : oidcAuthorizationPath(provider.providerID)
                        )
                      }}>
                      <span>
                        <strong>
                          {t('auth.sign_in_with', {
                            provider: provider.displayName || humanizeTechnicalLabel(provider.adapterID)
                          })}
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
  const returnTo = pageQuery.get('return_to')
  const query = new URLSearchParams()
  if (returnTo) query.set('return_to', returnTo)
  query.set('flow', pageQuery.get('flow') ?? '')

  if (pageQuery.get('oauth') === '1') query.set('oauth', '1')

  return `/sessions/oidc/${encodeURIComponent(providerID)}/authorization?${query}`
}

function siteAuthorizationPath(loginPath: string, flow: string): string {
  const url = new URL(loginPath, window.location.origin)
  if (url.origin !== window.location.origin) throw new Error('Site login must use the current origin')
  url.searchParams.set('flow', flow)
  return url.pathname + url.search
}
