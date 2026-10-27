import { Button, Card, CardContent, CardHeader, Skeleton } from '@ankole/uikit'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { loginProviders, selectLoginIdentity } from '../common/api/generated/sdk.gen'
import type { LoginProvidersResponse } from '../common/api/generated/types.gen'
import { localizedText } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { ThemeToggle } from '../common/theme-toggle'
import { EmailOtpForm } from './email-otp-form'
import { InvitationJoin } from './invitation-join'
import { readLoginSearch } from './login-params'
import { SessionScreen } from './session-screen'
import { AuthSlotsContext, type AuthAppSlots } from './slots'
export type { AuthAppSlots } from './slots'

export interface AuthLoginPresentation {
  title?: string
  sendLabel?: string
  providerDivider?: string
  verificationTitle?: string
}

export function AuthApp({
  slots = {},
  loginPresentation
}: { slots?: AuthAppSlots; loginPresentation?: AuthLoginPresentation } = {}) {
  return (
    <AuthSlotsContext value={slots}>
      <AuthScreen loginPresentation={loginPresentation} />
    </AuthSlotsContext>
  )
}

function AuthScreen({ loginPresentation }: { loginPresentation?: AuthLoginPresentation }) {
  const status = Number(document.querySelector<HTMLMetaElement>('meta[name="ankole-response-status"]')?.content ?? 200)
  if (window.location.pathname.startsWith('/join/')) return <InvitationJoin />
  if (window.location.pathname !== '/sessions/new' || status >= 400) return <SessionScreen invalid={status >= 400} />
  return <LoginApp presentation={loginPresentation} />
}

function LoginApp({ presentation = {} }: { presentation?: AuthLoginPresentation }) {
  const { t, i18n } = useTranslation()
  const [emailStep, setEmailStep] = useState<'email' | 'code'>('email')
  const { query, context, authorizationParams } = readLoginSearch()
  const providers = useQuery({
    queryKey: ['identity-providers', query],
    queryFn: () => loginProviders({ query })
  })
  const siteLogin = providers.data?.purpose === 'site'
  useEffect(() => {
    document.title = presentation.title ?? t(siteLogin ? 'auth.register_document_title' : 'auth.document_title')
  }, [t, siteLogin, presentation.title])
  const selection = useMutation({
    mutationFn: (authenticationRef: string) =>
      selectLoginIdentity({
        body: {
          data: {
            authenticationRef,
            oauthRequest: context.oauthRequest,
            returnTo: context.returnTo,
            prompt: context.prompt,
            reauth: context.reauth
          }
        }
      }),
    onSuccess: data => window.location.assign(data.returnTo)
  })
  const list = providers.data?.providers ?? []
  const identities = providers.data?.identities ?? []
  const hasEmail = list.some(provider => provider.providerID === 'email_otp')
  const sso = list.filter(provider => provider.kind === 'oidc')
  const verifying = Boolean(presentation.verificationTitle && emailStep === 'code')
  const hasIdentities = !verifying && identities.length > 0
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
            <h1>
              {verifying
                ? presentation.verificationTitle
                : (presentation.title ?? t(siteLogin ? 'auth.register_title' : 'auth.title'))}
            </h1>
            {!verifying && <p>{t(siteLogin ? 'auth.register_description' : 'auth.description')}</p>}
          </div>
        </CardHeader>
        <CardContent className="grid gap-5">
          <ErrorBlock error={providers.error ?? selection.error} />
          {hasIdentities && (
            <div className="grid gap-2.5">
              {identities.map(identity => (
                <Button
                  key={`${identity.authenticationRef}:${identity.principalUID}`}
                  variant="outline"
                  className="w-full"
                  disabled={selection.isPending}
                  onClick={() => selection.mutate(identity.authenticationRef)}>
                  {t('auth.continue_identity', {
                    name: identity.displayName,
                    provider: identityProviderLabel(identity.providerID, list, i18n.language, t('auth.email_login'))
                  })}
                </Button>
              ))}
            </div>
          )}
          {hasIdentities && hasEmail && <div className="border-t border-border/70" role="separator" />}
          {!verifying && providers.data?.requireSSOForMembers && (
            <p role="note" className="rounded-control bg-muted/50 px-3 py-2 text-xs text-muted-foreground">
              {t('auth.sso_required')}
            </p>
          )}
          {hasEmail && (
            <EmailOtpForm
              context={context}
              sendLabel={presentation.sendLabel}
              compactVerification={Boolean(presentation.verificationTitle)}
              onStepChange={presentation.verificationTitle ? setEmailStep : undefined}
            />
          )}
          {!verifying && sso.length > 0 && (
            <div className="ak-login-list mt-0">
              {(hasEmail || hasIdentities) && (
                <div className="ak-login-divider mt-0">{presentation.providerDivider ?? t('auth.or_sso')}</div>
              )}
              {sso.map(provider => (
                <Button
                  variant="outline"
                  key={provider.providerID}
                  onClick={() => {
                    const url = new URL(
                      `/sessions/oidc/${encodeURIComponent(provider.providerID)}/authorization`,
                      window.location.origin
                    )
                    url.search = authorizationParams.toString()
                    window.location.assign(url)
                  }}>
                  {t('auth.sign_in_with', {
                    provider:
                      localizedText(provider.displayName, i18n.language) ?? humanizeTechnicalLabel(provider.providerID)
                  })}
                </Button>
              ))}
            </div>
          )}
          {providers.isLoading && <Skeleton className="h-16 w-full" aria-label={t('common.loading')} />}
          {!providers.error && !providers.isLoading && list.length === 0 && <p>{t('auth.no_providers')}</p>}
        </CardContent>
      </Card>
    </main>
  )
}

function identityProviderLabel(
  providerID: string,
  providers: LoginProvidersResponse['providers'],
  locale: string,
  emailLabel: string
): string {
  if (providerID === 'email_otp') return emailLabel
  const matched = providers.find(provider => provider.providerID === providerID)
  return localizedText(matched?.displayName, locale) ?? humanizeTechnicalLabel(providerID)
}
