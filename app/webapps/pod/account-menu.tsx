import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  toast,
  useTheme
} from '@ankole/uikit'
import {
  RiAddLine,
  RiCheckLine,
  RiExpandUpDownLine,
  RiExternalLinkLine,
  RiLogoutBoxRLine,
  RiLogoutCircleRLine,
  RiMoonLine,
  RiSunLine,
  RiUser3Line
} from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { useLocation, useNavigate } from '@tanstack/react-router'
import { activateBrowserAccount, browserSession, deleteAuthSession } from '../common/api/generated/sdk.gen'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
type BrowserAccount = BrowserSessionResponse['accounts'][number] | BrowserSessionResponse['pendingAccounts'][number]
import { authenticationRef, podID } from '../common/browser-context'
import { endPodSession } from '../common/browser-session'
import { humanizeTechnicalLabel } from '../common/humanize-technical-label'
import { requestErrorMessage } from '../common/request-errors'

const initial = (name: string) => [...name.trim()][0]?.toUpperCase() ?? '?'

/**
 * The person and organization of this document, other accounts that this browser has proved,
 * and the way out. `extra` adds build-specific items, such as a SaaS account center.
 */
export function AccountMenu({ extra }: { extra?: ReactNode }) {
  const { t } = useTranslation()
  const location = useLocation()
  const navigate = useNavigate()
  const { resolvedTheme, setTheme } = useTheme()
  const session = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: ({ signal }) => browserSession({ signal }),
    staleTime: 60_000
  })
  const activate = useMutation({
    mutationFn: (account: BrowserAccount) =>
      activateBrowserAccount({
        body: { data: { authenticationRef: account.authenticationRef, tenantID: account.tenant.id } }
      }),
    onSuccess: ({ podURL }, account) => {
      const keepPage = account.tenant.id === podID() && new URL(podURL).pathname === '/'
      window.location.assign(keepPage ? location.href : podURL)
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const signOut = useMutation({
    mutationFn: endPodSession,
    onSettled: () => {
      const tenant = podID()
      window.location.assign(`/sessions/new${tenant ? `?${new URLSearchParams({ tenant_id: tenant })}` : ''}`)
    }
  })
  const signOutAll = useMutation({
    mutationFn: () => deleteAuthSession(),
    onSuccess: () => window.location.assign('/sessions/logged-out')
  })
  const data = session.data
  const name = data?.displayName ?? (session.isPending ? t('pod.content.loading') : t('pod.sidebar.account'))
  const tenantName = data?.tenant?.displayName ?? ''
  const current = (account: BrowserAccount) =>
    account.tenant.id === podID() && account.principalUID === data?.principalUID
  const returnTo = encodeURIComponent(location.href)
  return (
    <DropdownMenu onOpenChange={open => open && void session.refetch()}>
      <DropdownMenuTrigger
        className="pod-account-trigger"
        aria-label={t('pod.sidebar.account_menu', { name, tenant: tenantName })}>
        <span aria-hidden className="pod-account-mark">
          {initial(tenantName || name)}
        </span>
        <span className="pod-account-text">
          <span className="truncate">{tenantName || name}</span>
          {tenantName && <small className="truncate">{name}</small>}
        </span>
        <RiExpandUpDownLine aria-hidden className="pod-account-chevron" />
      </DropdownMenuTrigger>
      <DropdownMenuContent side="top" align="start" sideOffset={6} className="pod-account-menu">
        {session.error && <DropdownMenuLabel role="alert">{requestErrorMessage(session.error)}</DropdownMenuLabel>}
        {data?.accounts?.length ? (
          <DropdownMenuGroup>
            <DropdownMenuLabel>{t('pod.sidebar.accounts')}</DropdownMenuLabel>
            {data.accounts.map(account => {
              const selected = current(account)
              return (
                <DropdownMenuItem
                  key={`${account.authenticationRef}:${account.tenant.id}`}
                  className="pod-account-option"
                  disabled={activate.isPending}
                  aria-current={selected ? 'true' : undefined}
                  onClick={() => (selected ? undefined : activate.mutate(account))}>
                  <span aria-hidden className="pod-account-mark">
                    {initial(account.tenant.displayName)}
                  </span>
                  <span className="pod-account-text">
                    <span className="truncate">{account.tenant.displayName}</span>
                    <small className="truncate">
                      {account.tenant.slug} · {account.displayName}
                    </small>
                    <small className="truncate">
                      {t('auth.sign_in_with', {
                        provider:
                          account.providerID === 'email_otp'
                            ? t('auth.email_login')
                            : humanizeTechnicalLabel(account.providerID)
                      })}
                    </small>
                  </span>
                  {selected && <RiCheckLine aria-hidden className="ml-auto" />}
                </DropdownMenuItem>
              )
            })}
          </DropdownMenuGroup>
        ) : null}
        {data?.pendingAccounts.map(account => (
          <DropdownMenuItem
            key={`${account.authenticationRef}:${account.tenant.id}`}
            disabled={activate.isPending}
            onClick={() => activate.mutate(account)}>
            {t('auth.pending_space', { name: account.tenant.displayName })}
            {account.requiresSSO && <small>{t('auth.sso_required')}</small>}
          </DropdownMenuItem>
        ))}
        <DropdownMenuItem onClick={() => void navigate({ to: '/me' })}>
          <RiUser3Line aria-hidden />
          {t('pod.account.title')}
        </DropdownMenuItem>
        <DropdownMenuItem onClick={() => window.location.assign(`/sessions/new?switch=1&return_to=${returnTo}`)}>
          <RiAddLine aria-hidden />
          {t('pod.sidebar.add_account')}
        </DropdownMenuItem>
        {data?.consoleURL && (
          <DropdownMenuItem onClick={() => window.open(data.consoleURL!, '_blank', 'noopener')}>
            <RiExternalLinkLine aria-hidden />
            {t('pod.sidebar.site_console')}
          </DropdownMenuItem>
        )}
        {extra}
        <DropdownMenuSeparator />
        <DropdownMenuGroup>
          <DropdownMenuLabel>{t('pod.sidebar.theme')}</DropdownMenuLabel>
          <DropdownMenuRadioGroup value={resolvedTheme ?? 'light'} onValueChange={value => setTheme(String(value))}>
            <DropdownMenuRadioItem value="light">
              <RiSunLine aria-hidden />
              {t('pod.sidebar.theme_light')}
            </DropdownMenuRadioItem>
            <DropdownMenuRadioItem value="dark">
              <RiMoonLine aria-hidden />
              {t('pod.sidebar.theme_dark')}
            </DropdownMenuRadioItem>
          </DropdownMenuRadioGroup>
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <DropdownMenuItem disabled={signOut.isPending} onClick={() => signOut.mutate()}>
          <RiLogoutBoxRLine aria-hidden />
          {data?.displayName ? t('pod.sidebar.sign_out_name', { name: data.displayName }) : t('pod.sidebar.sign_out')}
        </DropdownMenuItem>
        <DropdownMenuItem disabled={signOutAll.isPending} onClick={() => signOutAll.mutate()}>
          <RiLogoutCircleRLine aria-hidden />
          {t('auth.sign_out_all')}
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
