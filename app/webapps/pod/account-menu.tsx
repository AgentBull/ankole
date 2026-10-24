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
  RiMoonLine,
  RiSunLine
} from '@remixicon/react'
import { useMutation, useQuery } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { useLocation } from '@tanstack/react-router'
import { activateBrowserAccount, browserSession } from '../common/api/generated/sdk.gen'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
type BrowserAccount = BrowserSessionResponse['accounts'][number]
import { authenticationRef, podID } from '../common/browser-context'
import { endPodSession } from '../common/browser-session'
import { requestErrorMessage } from '../common/request-errors'

const initial = (name: string) => [...name.trim()][0]?.toUpperCase() ?? '?'

/**
 * The person and organization of this document, other accounts that this browser has proved,
 * and the way out. `extra` adds build-specific items, such as a SaaS account center.
 */
export function AccountMenu({ extra }: { extra?: ReactNode }) {
  const { t } = useTranslation()
  const location = useLocation()
  const { resolvedTheme, setTheme } = useTheme()
  const session = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: ({ signal }) => browserSession({ signal }),
    staleTime: 60_000
  })
  const activate = useMutation({
    mutationFn: (account: BrowserAccount) =>
      activateBrowserAccount({ body: { data: { authenticationRef: account.authenticationRef } } }),
    onSuccess: ({ podURL }, account) => {
      const sameTenant = account.tenant.id === podID()
      window.location.assign(sameTenant ? location.href : podURL)
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
                  key={account.authenticationRef}
                  className="pod-account-option"
                  disabled={activate.isPending}
                  aria-current={selected ? 'true' : undefined}
                  onClick={() => (selected ? undefined : activate.mutate(account))}>
                  <span aria-hidden className="pod-account-mark">
                    {initial(account.tenant.displayName)}
                  </span>
                  <span className="pod-account-text">
                    <span className="truncate">{account.tenant.displayName}</span>
                    <small className="truncate">{account.displayName}</small>
                  </span>
                  {selected && <RiCheckLine aria-hidden className="ml-auto" />}
                </DropdownMenuItem>
              )
            })}
          </DropdownMenuGroup>
        ) : null}
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
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
