import { RiLoginCircleLine } from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import { api, unwrap } from '@/lib/api'
import { Alert, AlertDescription, AlertTitle } from '@/uikit/components/alert'
import { Button } from '@/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@/uikit/components/card'
import { mountSpa } from '../mount-spa'

/**
 * Renders the anonymous sign-in page after setup is complete.
 *
 * The server guards `/sessions/*`; this SPA only lists enabled providers and
 * starts OIDC authorization while preserving the requested `return_to` target.
 */
function SessionsApp() {
  const { t } = useTranslation()
  const providers = useQuery({
    queryKey: ['identity-providers'],
    queryFn: () => unwrap(api['identity-providers'].get())
  })
  const mutation = useMutation({
    mutationFn: async (providerId: string) => {
      const returnTo = new URLSearchParams(window.location.search).get('return_to') ?? '/console'
      return unwrap(
        api['identity-providers']({ providerId }).oidc.authorizations.post({}, { query: { return_to: returnTo } })
      )
    },
    onSuccess: result => window.location.assign(result.authorizationUrl)
  })

  return (
    <main
      data-theme="dark"
      className="flex min-h-screen items-center justify-center bg-background px-4 text-foreground">
      <Card className="w-full max-w-md rounded-none border-border/70 bg-background/95">
        <CardHeader>
          <CardTitle>{t('sessions.title')}</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-5">
          {providers.error || mutation.error ? (
            <Alert variant="destructive">
              <AlertTitle>{t('sessions.failed_title')}</AlertTitle>
              <AlertDescription>{String(providers.error ?? mutation.error)}</AlertDescription>
            </Alert>
          ) : null}
          <div className="grid gap-3">
            {(providers.data?.providers ?? []).map(provider => (
              <Button
                key={provider.providerId}
                disabled={mutation.isPending}
                onClick={() => mutation.mutate(provider.providerId)}>
                {t('sessions.sign_in_with', { providerId: provider.providerId })}
                <RiLoginCircleLine data-icon="inline-end" />
              </Button>
            ))}
            {providers.data?.providers.length === 0 ? (
              <p className="text-sm text-muted-foreground">{t('sessions.no_identity_provider')}</p>
            ) : null}
          </div>
        </CardContent>
      </Card>
    </main>
  )
}

mountSpa(<SessionsApp />)
