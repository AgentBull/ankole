import { Alert, AlertDescription } from '@ankole/uikit/components/alert'
import { Button } from '@ankole/uikit/components/button'
import { Card, CardContent, CardHeader } from '@ankole/uikit/components/card'
import { Skeleton } from '@ankole/uikit/components/skeleton'
import { useQuery } from '@tanstack/react-query'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { logoutConfirmation } from '../common/api/generated/sdk.gen'
import { BrandIcon } from '../common/brand'
import { clearDataTenant } from '../common/browser-session'
import { signInMethodLabel } from '../common/sign-in-method'
import { ThemeToggle } from '../common/theme-toggle'
import { signInReturnTo } from './login-params'

export type SessionScreenView =
  | {
      kind: 'not_found'
      titleKey: 'auth.not_found_title'
      actionLabelKey: 'auth.go_home'
      actionHref: string
    }
  | {
      kind: 'failed'
      titleKey: 'auth.session_expired_title' | 'common.error'
      descriptionKey: string
      actionLabelKey: 'auth.back_to_sign_in'
      actionHref: string
    }
  | {
      kind: 'confirm_logout'
      titleKey: 'auth.logout_title'
    }
  | {
      kind: 'signed_out'
      titleKey: 'auth.logout_cancelled' | 'auth.logged_out'
      descriptionKey: 'auth.logout_cancelled_description' | 'auth.logged_out_description'
      actionLabelKey: 'auth.back_to_sign_in'
      actionHref: string
    }

const AUTH_ERROR_DESCRIPTIONS: Record<string, string> = {
  account_disabled: 'auth.account_disabled',
  tenant_suspended: 'auth.tenant_suspended',
  login_subject_mismatch: 'auth.login_subject_mismatch'
}

export function resolveSessionScreenView({
  authError,
  cancelled,
  confirm,
  failed,
  isNotFound,
  returnTo
}: {
  authError: string
  cancelled: boolean
  confirm: boolean
  failed: boolean
  isNotFound: boolean
  returnTo: string
}): SessionScreenView {
  if (isNotFound) {
    return {
      kind: 'not_found',
      titleKey: 'auth.not_found_title',
      actionLabelKey: 'auth.go_home',
      actionHref: '/'
    }
  }
  if (failed) {
    const isExpired = authError === 'login_expired' || !authError
    const descriptionKey =
      AUTH_ERROR_DESCRIPTIONS[authError] ?? (isExpired ? 'auth.session_expired_description' : 'auth.error_description')
    return {
      kind: 'failed',
      titleKey: isExpired ? 'auth.session_expired_title' : 'common.error',
      descriptionKey,
      actionLabelKey: 'auth.back_to_sign_in',
      actionHref: returnTo
    }
  }
  if (confirm) {
    return {
      kind: 'confirm_logout',
      titleKey: 'auth.logout_title'
    }
  }
  return {
    kind: 'signed_out',
    titleKey: cancelled ? 'auth.logout_cancelled' : 'auth.logged_out',
    descriptionKey: cancelled ? 'auth.logout_cancelled_description' : 'auth.logged_out_description',
    actionLabelKey: 'auth.back_to_sign_in',
    actionHref: returnTo
  }
}

export function SessionScreen({ invalid }: { invalid: boolean }) {
  const { t, i18n } = useTranslation()
  const [submitting, setSubmitting] = useState(false)
  const query = new URLSearchParams(window.location.search)
  const request = query.get('request') ?? ''
  const returnTo = signInReturnTo(query.get('return_to'), window.location.origin)
  const status = Number(document.querySelector<HTMLMetaElement>('meta[name="ankole-response-status"]')?.content ?? 200)
  const authError = document.querySelector<HTMLMetaElement>('meta[name="ankole-auth-error"]')?.content ?? ''
  const isNotFound = authError === 'not_found' || status === 404
  const confirm = window.location.pathname === '/oauth/logout/confirm' && !invalid && !isNotFound
  const cancelled = query.get('cancelled') === '1'

  useEffect(() => {
    if (
      window.location.pathname.startsWith('/sessions/oidc/') &&
      (window.location.search.includes('code=') || window.location.search.includes('state='))
    ) {
      window.history.replaceState(window.history.state, '', '/sessions/new')
    }
  }, [])

  const details = useQuery({
    queryKey: ['logout-confirmation', request],
    queryFn: () => logoutConfirmation({ path: { id: request } }),
    enabled: confirm,
    retry: false
  })
  const view = resolveSessionScreenView({
    authError,
    cancelled,
    confirm,
    failed: invalid || Boolean(details.error),
    isNotFound,
    returnTo
  })
  const csrf = document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ''

  const renderCardBody = () => {
    switch (view.kind) {
      case 'not_found':
        return <p className="text-sm text-fg-secondary">{t('auth.not_found_description')}</p>
      case 'failed':
        return (
          <Alert variant="destructive">
            <AlertDescription>{t(view.descriptionKey)}</AlertDescription>
          </Alert>
        )
      case 'confirm_logout':
        if (details.isPending) {
          return <Skeleton className="h-24 w-full" aria-label={t('common.loading')} />
        }
        return (
          <>
            <p>
              {details.data?.clientName
                ? t('auth.logout_client', { client: details.data.clientName })
                : t('auth.logout_description')}
            </p>
            {details.data?.identity ? (
              <p className="text-sm text-fg-secondary">
                {t('auth.current_identity', {
                  name: details.data.identity.displayName,
                  provider: signInMethodLabel(details.data.identity, i18n.language, t('auth.email_login'))
                })}
              </p>
            ) : (
              <p className="text-sm text-fg-secondary">{t('auth.no_current_identity')}</p>
            )}
            <form
              action="/oauth/logout/confirm"
              method="post"
              className="flex flex-wrap gap-3"
              onSubmit={event => {
                if (submitting) event.preventDefault()
                else {
                  const submitter = (event.nativeEvent as SubmitEvent).submitter
                  if (submitter?.getAttribute('name') === 'action' && submitter.getAttribute('value') === 'confirm') {
                    clearDataTenant()
                  }
                  setSubmitting(true)
                }
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
      case 'signed_out':
        return <p>{t(view.descriptionKey)}</p>
    }
  }

  return (
    <main className="ak-auth-page relative">
      <ThemeToggle className="absolute top-4 right-4 border border-border-subtle bg-page/80 backdrop-blur" />
      <Card className="ak-auth-card">
        <CardHeader>
          <div className="ak-auth-heading">
            <div className="ak-auth-brand">
              <BrandIcon className="size-9" />
            </div>
            <h1>{t(view.titleKey)}</h1>
          </div>
        </CardHeader>
        <CardContent className="grid gap-5">
          {renderCardBody()}
          {view.kind !== 'confirm_logout' ? (
            <Button type="button" variant="outline" onClick={() => window.location.assign(view.actionHref)}>
              {t(view.actionLabelKey)}
            </Button>
          ) : null}
        </CardContent>
      </Card>
    </main>
  )
}
