import { Button, Card, CardContent, CardHeader, Skeleton } from '@ankole/uikit'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { acceptInvitation, browserSession, previewInvitation } from '../common/api/generated/sdk.gen'
import { BrandIcon } from '../common/brand'
import { localizedText } from '../common/config-fields'
import { ErrorBlock } from '../common/error-block'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { ThemeToggle } from '../common/theme-toggle'
import { invitationToken } from './state/join-space'

export function InvitationJoin() {
  const { t, i18n } = useTranslation()
  const invitation = window.location.pathname
  const token = () => invitationToken(invitation, window.location.origin)
  const preview = useQuery({
    queryKey: ['invitation', invitation],
    queryFn: () => previewInvitation({ path: { token: token() } }),
    retry: false
  })
  const session = useQuery({ queryKey: ['invitation-browser-session'], queryFn: () => browserSession(), retry: false })
  const accept = useMutation({
    mutationFn: (authenticationRef: string) =>
      acceptInvitation({ path: { token: token() }, body: { data: { authenticationRef } } }),
    onSuccess: result => window.location.assign(result.podURL)
  })
  const data = preview.data
  const siteAuthentications = data?.emailOTPAvailable ? (session.data?.siteAuthentications ?? []) : []
  const hasSiteAuthentications = siteAuthentications.length > 0
  const busy = accept.isPending
  return (
    <main className="ak-auth-page relative">
      <ThemeToggle className="absolute top-4 right-4 border border-border bg-background/80 backdrop-blur" />
      <Card className="ak-auth-card">
        <CardHeader>
          <div className="ak-auth-heading">
            <div className="ak-auth-brand">
              <BrandIcon className="size-9" />
            </div>
            {preview.isPending ? (
              <Skeleton className="my-1 h-9 w-48" aria-hidden />
            ) : (
              <h1>{t('auth.join_title', { name: data?.displayName ?? 'Ankole' })}</h1>
            )}
            {data && <p>{t(data.membership === 'guest' ? 'auth.join_guest' : 'auth.join_member')}</p>}
          </div>
        </CardHeader>
        <CardContent className="grid gap-4">
          <ErrorBlock error={preview.error ?? accept.error} />
          {preview.isPending && <Skeleton className="h-24 w-full" aria-label={t('common.loading')} />}
          {data && (
            <>
              {siteAuthentications.map((authentication, index) => (
                <Button
                  key={authentication.authenticationRef}
                  variant={index === 0 ? 'default' : 'outline'}
                  disabled={busy}
                  onClick={() => accept.mutate(authentication.authenticationRef)}>
                  {t('auth.continue_email', { email: authentication.identifier })}
                </Button>
              ))}
              {data.emailOTPAvailable && (
                <Button
                  variant={hasSiteAuthentications ? 'outline' : 'default'}
                  disabled={busy}
                  onClick={() => window.location.assign(data.emailLoginURL)}>
                  {t('auth.join_with_email')}
                </Button>
              )}
              {data.oidcProviders.map(provider => (
                <Button
                  key={provider.providerID}
                  variant="outline"
                  disabled={busy}
                  onClick={() => {
                    const url = new URL(
                      `sessions/oidc/${encodeURIComponent(provider.providerID)}/authorization`,
                      data.podURL
                    )
                    url.searchParams.set('invitation_token', token())
                    window.location.assign(url)
                  }}>
                  {t('auth.sign_in_with', {
                    provider:
                      localizedText(provider.displayName, i18n.language) ?? humanizeTechnicalLabel(provider.providerID)
                  })}
                </Button>
              ))}
              {!data.emailOTPAvailable && data.oidcProviders.length === 0 && <p>{t('auth.join_unavailable')}</p>}
            </>
          )}
        </CardContent>
      </Card>
    </main>
  )
}
