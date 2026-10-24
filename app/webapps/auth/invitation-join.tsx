import { Button, Card, CardContent, CardHeader } from '@ankole/uikit'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import {
  acceptInvitation,
  beginInvitationLogin,
  browserSession,
  previewInvitation
} from '../common/api/generated/sdk.gen'
import { localizedText } from '../common/config-fields'
import { invitationToken } from './state/join-space'
import { ErrorBlock } from '../common/error-block'

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
  const begin = useMutation({ mutationFn: () => beginInvitationLogin({ path: { token: token() } }) })
  const accept = useMutation({
    mutationFn: (authenticationRef: string) =>
      acceptInvitation({ path: { token: token() }, body: { data: { authenticationRef } } }),
    onSuccess: result => window.location.assign(result.podURL)
  })
  const data = preview.data
  return (
    <main className="ak-auth-page">
      <Card className="ak-auth-card">
        <CardHeader>
          <h1>{t('auth.join_title', { name: data?.displayName ?? 'Ankole' })}</h1>
          {data && <p>{t(data.membership === 'guest' ? 'auth.join_guest' : 'auth.join_member')}</p>}
        </CardHeader>
        <CardContent className="grid gap-4">
          <ErrorBlock error={preview.error ?? begin.error ?? accept.error} />
          {data && (
            <>
              {data.emailOTPAvailable &&
                (session.data?.siteAuthentications ?? []).map(authentication => (
                  <Button
                    key={authentication.authenticationRef}
                    variant="outline"
                    disabled={accept.isPending}
                    onClick={() => accept.mutate(authentication.authenticationRef)}>
                    {t('auth.continue_email', { email: authentication.identifier })}
                  </Button>
                ))}
              {data.emailOTPAvailable && (
                <Button
                  disabled={begin.isPending}
                  onClick={() =>
                    begin.mutate(undefined, {
                      onSuccess: result => {
                        const url = new URL('sessions/new', data.podURL)
                        url.searchParams.set('flow', result.flow)
                        window.location.assign(url)
                      }
                    })
                  }>
                  {t('auth.join_with_email')}
                </Button>
              )}
              {data.oidcProviders.map(provider => (
                <Button
                  key={provider.providerID}
                  variant="outline"
                  disabled={begin.isPending}
                  onClick={() =>
                    begin.mutate(undefined, {
                      onSuccess: result => {
                        const url = new URL(
                          `sessions/oidc/${encodeURIComponent(provider.providerID)}/authorization`,
                          data.podURL
                        )
                        url.searchParams.set('flow', result.flow)
                        window.location.assign(url)
                      }
                    })
                  }>
                  {t('auth.sign_in_with', { provider: localizedText(provider.displayName, i18n.language) })}
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
