import { Alert, AlertDescription, AlertTitle } from '@ankole/uikit/components/alert'
import { Button } from '@ankole/uikit/components/button'
import { Card, CardContent, CardHeader } from '@ankole/uikit/components/card'
import { Skeleton } from '@ankole/uikit/components/skeleton'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { internalAPIGet } from '../common/internal-api-client'
import { ThemeToggle } from '../common/theme-toggle'

export function SessionScreen({ invalid }: { invalid: boolean }) {
  const { t } = useTranslation()
  const [submitting, setSubmitting] = useState(false)
  const query = new URLSearchParams(window.location.search)
  const request = query.get('request') ?? ''
  const confirm = window.location.pathname === '/oauth/logout/confirm' && !invalid
  const cancelled = query.get('cancelled') === '1'
  const details = useQuery({
    queryKey: ['logout-confirmation', request],
    queryFn: () =>
      internalAPIGet<{
        clientName: string | null
        identity: { displayName: string; providerID: string } | null
      }>(`/.internal-apis/oidc-logout/${encodeURIComponent(request)}`),
    enabled: confirm,
    retry: false
  })
  const failed = invalid || Boolean(details.error)
  const title = failed
    ? 'auth.session_expired_title'
    : confirm
      ? 'auth.logout_title'
      : cancelled
        ? 'auth.logout_cancelled'
        : 'auth.logged_out'
  const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ''

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
            <h1>{t(title)}</h1>
          </div>
        </CardHeader>
        <CardContent className="grid gap-5">
          {failed ? (
            <Alert variant="destructive">
              <AlertTitle>{t('auth.session_expired_title')}</AlertTitle>
              <AlertDescription>{t('auth.session_expired_description')}</AlertDescription>
            </Alert>
          ) : confirm ? (
            details.isPending ? (
              <Skeleton className="h-24 w-full" aria-label={t('common.loading')} />
            ) : (
              <>
                <p>
                  {details.data?.clientName
                    ? t('auth.logout_client', { client: details.data.clientName })
                    : t('auth.logout_description')}
                </p>
                {details.data?.identity ? (
                  <p className="text-sm text-muted-foreground">
                    {t('auth.current_identity', {
                      name: details.data.identity.displayName,
                      provider: details.data.identity.providerID
                    })}
                  </p>
                ) : (
                  <p className="text-sm text-muted-foreground">{t('auth.no_current_identity')}</p>
                )}
                <form
                  action="/oauth/logout/confirm"
                  method="post"
                  className="flex flex-wrap gap-3"
                  onSubmit={event => {
                    if (submitting) event.preventDefault()
                    else setSubmitting(true)
                  }}
                  aria-busy={submitting}>
                  <input type="hidden" name="_csrf_token" value={csrf} />
                  <input type="hidden" name="request" value={request} />
                  <Button type="submit" name="action" value="confirm" aria-disabled={submitting}>
                    {t(submitting ? 'auth.logging_out' : 'auth.logout_confirm')}
                  </Button>
                  <Button type="submit" name="action" value="cancel" variant="outline" aria-disabled={submitting}>
                    {t('common.cancel')}
                  </Button>
                </form>
              </>
            )
          ) : (
            <p>{t(cancelled ? 'auth.logout_cancelled_description' : 'auth.logged_out_description')}</p>
          )}
          {!confirm || failed ? (
            <Button type="button" variant="outline" onClick={() => window.location.assign('/sessions/new')}>
              {t('auth.back_to_sign_in')}
            </Button>
          ) : null}
        </CardContent>
      </Card>
    </main>
  )
}
