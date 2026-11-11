import {
  Avatar,
  AvatarFallback,
  cn,
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuGroup,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuRadioGroup,
  DropdownMenuRadioItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
  SidebarFooterButton,
  SidebarFooterLabel,
  Skeleton,
  toast,
  useTheme
} from '@ankole/uikit'
import {
  AddRegular,
  CheckmarkRegular,
  ChevronUpDownRegular,
  DeleteRegular,
  OpenRegular,
  PersonRegular,
  SettingsRegular,
  SignOutRegular,
  WeatherMoonRegular,
  WeatherSunnyRegular
} from '@ankole/uikit/icons'
import { useMutation, useQuery } from '@tanstack/react-query'
import { useState, type ComponentProps, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useLocation, useNavigate } from '@tanstack/react-router'
import { activateBrowserAccount, browserSession } from '../common/api/generated/sdk.gen'
import type { BrowserSessionResponse } from '../common/api/generated/types.gen'
type BrowserAccount = BrowserSessionResponse['accounts'][number] | BrowserSessionResponse['pendingAccounts'][number]
import { authenticationRef, podID, podLocation } from '../common/browser-context'
import { endAccountSession, endBrowserSession } from '../common/browser-session'
import { signInMethodLabel } from '../common/sign-in-method'
import { requestErrorMessage } from '../common/request-errors'
import { avatarInitials } from './avatar-initials'
import { currentProfileAvatarContext, profileAvatarURL, type ProfileAvatarContext } from './native-transfers'

const initial = avatarInitials

/**
 * The Pod's mark: its uploaded avatar, or the initials of its name, as an `Avatar` of the given size. The sidebar's
 * footer row sizes the mark it holds.
 */
export function SpaceMark({
  name,
  avatarURL,
  context,
  size,
  className
}: {
  name: string
  avatarURL?: string | null
  context: ProfileAvatarContext
  size?: ComponentProps<typeof Avatar>['size']
  className?: string
}) {
  const [failedSource, setFailedSource] = useState<string>()
  const source = profileAvatarURL(avatarURL, context)
  return (
    <Avatar aria-hidden size={size} className={cn('font-semibold', className)}>
      {source && failedSource !== source ? (
        <img
          src={source}
          alt=""
          className="size-full rounded-full object-cover"
          onError={() => setFailedSource(source)}
        />
      ) : (
        <AvatarFallback className="text-foreground">{initial(name)}</AvatarFallback>
      )}
    </Avatar>
  )
}

/** Where the signed-in account loads avatars from: its own Pod account when the browser lists it, else this page. */
export function sessionAvatarContext(data: BrowserSessionResponse | undefined): ProfileAvatarContext {
  const account = data?.accounts.find(
    account => account.tenant.id === podID() && account.principalUID === data.principalUID
  )
  return account
    ? { podURL: account.podURL, authenticationRef: account.authenticationRef }
    : currentProfileAvatarContext()
}

/**
 * The sidebar's account row: the Pod's mark and name with the signed-in person's name. Its menu holds the
 * organizations that this browser has proved, the person's settings, the Pod's settings and its Trash, the theme,
 * and the way out. `extra` adds build-specific items, such as a SaaS account center.
 */
export function AccountMenu({ extra }: { extra?: ReactNode }) {
  const { t, i18n } = useTranslation()
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
    mutationFn: endAccountSession,
    onSettled: () => window.location.assign('/sessions/new')
  })
  const signOutAll = useMutation({
    mutationFn: endBrowserSession,
    onSuccess: () => window.location.assign('/sessions/logged-out')
  })
  const data = session.data
  const name = data?.displayName ?? (session.isPending ? t('pod.content.loading') : t('pod.sidebar.account'))
  const tenantName = data?.tenant?.displayName ?? ''
  const current = (account: BrowserAccount) =>
    account.tenant.id === podID() && account.principalUID === data?.principalUID
  const currentAvatarContext = sessionAvatarContext(data)
  const returnTo = encodeURIComponent(location.href)
  return (
    <DropdownMenu onOpenChange={open => open && void session.refetch()}>
      <DropdownMenuTrigger
        render={<SidebarFooterButton />}
        className="pod-account-trigger"
        aria-label={
          tenantName
            ? t('pod.sidebar.account_menu', { name, tenant: tenantName })
            : t('pod.sidebar.account_menu_name', { name })
        }>
        {session.isPending ? (
          <>
            <Skeleton aria-hidden className="size-6.5 shrink-0 rounded-full" />
            <SidebarFooterLabel className="pod-account-text">
              <Skeleton aria-hidden className="h-4 w-24" />
            </SidebarFooterLabel>
          </>
        ) : (
          <>
            <SpaceMark name={tenantName || name} avatarURL={data?.tenant?.avatarURL} context={currentAvatarContext} />
            <SidebarFooterLabel className="pod-account-text">
              <span>{tenantName || name}</span>
              {tenantName && <small>{name}</small>}
            </SidebarFooterLabel>
          </>
        )}
        <ChevronUpDownRegular aria-hidden />
      </DropdownMenuTrigger>
      <DropdownMenuContent
        side="top"
        align="start"
        sideOffset={6}
        className="pod-account-menu w-[max(var(--anchor-width),240px)]">
        {session.error && <DropdownMenuLabel role="alert">{requestErrorMessage(session.error)}</DropdownMenuLabel>}
        {data?.accounts?.length ? (
          <DropdownMenuGroup>
            <DropdownMenuLabel>{t('pod.sidebar.accounts')}</DropdownMenuLabel>
            {data.accounts.map(account => {
              const selected = current(account)
              return (
                <DropdownMenuItem
                  key={`${account.authenticationRef}:${account.tenant.id}`}
                  className="pod-account-option min-h-10"
                  disabled={activate.isPending}
                  aria-current={selected ? 'true' : undefined}
                  onClick={() => (selected ? undefined : activate.mutate(account))}>
                  <SpaceMark
                    name={account.tenant.displayName}
                    avatarURL={account.tenant.avatarURL}
                    context={{ podURL: account.podURL, authenticationRef: account.authenticationRef }}
                    size="xs"
                  />
                  {/* Three compact 16px lines: the organization's name, then its handle and the sign-in method. */}
                  <span className="flex min-w-0 flex-1 flex-col text-65 leading-4 font-medium">
                    <span className="truncate">{account.tenant.displayName}</span>
                    <small className="truncate text-50 font-normal text-fg-tertiary">
                      {account.tenant.slug} · {account.displayName}
                    </small>
                    <small className="truncate text-50 font-normal text-fg-tertiary">
                      {t('auth.sign_in_with', {
                        provider: signInMethodLabel(account, i18n.language, t('auth.email_login'))
                      })}
                    </small>
                  </span>
                  {selected && <CheckmarkRegular aria-hidden className="ml-auto" />}
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
          <PersonRegular aria-hidden />
          {t('pod.account.title')}
        </DropdownMenuItem>
        {data?.canManagePod && (
          <DropdownMenuItem render={<Link to={podLocation('/settings').pathname} />}>
            <SettingsRegular aria-hidden />
            {t('pod.settings.title')}
          </DropdownMenuItem>
        )}
        <DropdownMenuItem render={<Link to={podLocation('/content/trash').pathname} />}>
          <DeleteRegular aria-hidden />
          {t('pod.content.trash')}
        </DropdownMenuItem>
        <DropdownMenuItem onClick={() => window.location.assign(`/sessions/new?switch=1&return_to=${returnTo}`)}>
          <AddRegular aria-hidden />
          {t('pod.sidebar.add_account')}
        </DropdownMenuItem>
        {data?.consoleURL && (
          <DropdownMenuItem onClick={() => window.open(data.consoleURL!, '_blank', 'noopener')}>
            <OpenRegular aria-hidden />
            {t('pod.sidebar.site_console')}
          </DropdownMenuItem>
        )}
        {extra}
        <DropdownMenuSeparator />
        <DropdownMenuGroup>
          <DropdownMenuLabel>{t('pod.sidebar.theme')}</DropdownMenuLabel>
          <DropdownMenuRadioGroup value={resolvedTheme ?? 'light'} onValueChange={value => setTheme(String(value))}>
            <DropdownMenuRadioItem value="light">
              <WeatherSunnyRegular aria-hidden />
              {t('pod.sidebar.theme_light')}
            </DropdownMenuRadioItem>
            <DropdownMenuRadioItem value="dark">
              <WeatherMoonRegular aria-hidden />
              {t('pod.sidebar.theme_dark')}
            </DropdownMenuRadioItem>
          </DropdownMenuRadioGroup>
        </DropdownMenuGroup>
        <DropdownMenuSeparator />
        <DropdownMenuItem disabled={signOut.isPending} onClick={() => signOut.mutate()}>
          <SignOutRegular aria-hidden />
          {tenantName ? t('pod.sidebar.sign_out_name', { name: tenantName }) : t('pod.sidebar.sign_out')}
        </DropdownMenuItem>
        {(data?.accounts.length ?? 0) > 1 && (
          <DropdownMenuItem disabled={signOutAll.isPending} onClick={() => signOutAll.mutate()}>
            <SignOutRegular aria-hidden />
            {t('auth.sign_out_all')}
          </DropdownMenuItem>
        )}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
