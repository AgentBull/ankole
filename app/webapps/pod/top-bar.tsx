import {
  Button,
  buttonVariants,
  SidebarTrigger,
  TopBar,
  TopBarActions,
  TopBarHistory,
  TopBarLeading,
  TopBarTitle
} from '@ankole/uikit'
import { ChevronLeftRegular, ChevronRightRegular, SearchRegular } from '@ankole/uikit/icons'
import { createContext, use, useCallback, useMemo, useState, useSyncExternalStore, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { useTranslation } from 'react-i18next'
import { Link, useRouter } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { browserSession } from '../common/api/generated/sdk.gen'
import { authenticationRef, podID, podLocation } from '../common/browser-context'
import { isApplePlatform } from '../common/platform'
import { ProfileMark, sessionAvatarContext } from './account-menu'
import { usePodCommandMenu } from './command-menu'

type TopBarSlot = HTMLElement | null

type TopBarSlots = {
  title: TopBarSlot
  people: TopBarSlot
  actions: TopBarSlot
  setTitle(node: TopBarSlot): void
  setPeople(node: TopBarSlot): void
  setActions(node: TopBarSlot): void
}

const PodTopBarContext = createContext<TopBarSlots>({
  title: null,
  people: null,
  actions: null,
  setTitle: () => {},
  setPeople: () => {},
  setActions: () => {}
})

/** Shares the top bar's title, people, and action slots with the routes rendered below it. */
export function PodTopBarProvider({ children }: { children: ReactNode }) {
  const [title, setTitle] = useState<TopBarSlot>(null)
  const [people, setPeople] = useState<TopBarSlot>(null)
  const [actions, setActions] = useState<TopBarSlot>(null)
  const value = useMemo(() => ({ title, people, actions, setTitle, setPeople, setActions }), [title, people, actions])
  return <PodTopBarContext value={value}>{children}</PodTopBarContext>
}

/**
 * The Pod shell's top bar spans the window above the sidebar and the content card. Above the sidebar column it
 * carries the Pod's mark and, while the sidebar is hidden, the sidebar toggle. Back and forward follow at the card's
 * edge, then the open route's path, which the route places through `PodTopBarTitle`. At its end, the people of the
 * open route (`PodTopBarPeople`) come before the search button, and the route's own actions (`PodTopBarActions`)
 * follow it.
 */
export function PodTopBar() {
  const { t } = useTranslation()
  const { setTitle, setPeople, setActions } = use(PodTopBarContext)
  const openCommand = usePodCommandMenu()
  const shortcut = isApplePlatform() ? '⌘K' : 'Ctrl+K'
  const search = t('pod.command.open')

  return (
    <TopBar className="@container">
      <TopBarLeading>
        <PodMark />
        {/* The leading zone hides the toggle while the sidebar is docked. */}
        <SidebarTrigger size="icon-lg" label={t('pod.sidebar.expand')} />
      </TopBarLeading>
      <PodHistory />
      <TopBarTitle ref={setTitle} />
      <TopBarActions>
        <div ref={setPeople} className="contents" />
        <div className="flex items-center">
          <Button
            variant="ghost"
            size="icon-lg"
            aria-label={search}
            aria-keyshortcuts="Meta+K Control+K"
            title={`${search} (${shortcut})`}
            onClick={openCommand}>
            <SearchRegular aria-hidden />
          </Button>
          <div ref={setActions} className="contents" />
        </div>
      </TopBarActions>
    </TopBar>
  )
}

/** Renders the open route's path, such as a Page's breadcrumb, in the title zone of the shell's top bar. */
export function PodTopBarTitle({ children }: { children: ReactNode }) {
  const { title } = use(PodTopBarContext)
  return title ? createPortal(children, title) : null
}

/** Renders the people of the open route, such as a document's collaborators, before the top bar's search button. */
export function PodTopBarPeople({ children }: { children: ReactNode }) {
  const { people } = use(PodTopBarContext)
  return people ? createPortal(children, people) : null
}

/** Renders the open route's actions at the end of the shell's top bar, after the search button. */
export function PodTopBarActions({ children }: { children: ReactNode }) {
  const { actions } = use(PodTopBarContext)
  return actions ? createPortal(children, actions) : null
}

/**
 * The Pod's mark, linking to the Pod's chat home. The mark names the Pod, whose name the sidebar's footer shows. On a
 * phone the bar leaves the mark out, so the open route's path keeps room beside its actions.
 */
function PodMark() {
  const session = useQuery({
    queryKey: ['pod-session', authenticationRef() ?? '', podID() ?? ''],
    queryFn: ({ signal }) => browserSession({ signal }),
    staleTime: 60_000
  })
  const name = session.data?.tenant?.displayName
  if (!name) return null
  return (
    <Link
      to={podLocation('/').pathname}
      aria-label={name}
      title={name}
      className={buttonVariants({ variant: 'ghost', size: 'icon-lg', className: 'max-md:hidden' })}>
      <ProfileMark
        name={name}
        avatarURL={session.data?.tenant?.avatarURL}
        context={sessionAvatarContext(session.data)}
        size="xs"
      />
    </Link>
  )
}

/**
 * Back and forward through the Pod router's history. Back is available after the first navigation inside the Pod;
 * forward follows the browser's Navigation API, and a browser without that API keeps forward enabled.
 */
function PodHistory() {
  const { t } = useTranslation()
  const router = useRouter()
  // The router writes a pushed entry to the browser in a microtask after it notifies, so the forward state is read
  // again once the entry exists.
  const subscribe = useCallback(
    (notify: () => void) =>
      router.history.subscribe(() => {
        notify()
        queueMicrotask(notify)
      }),
    [router]
  )
  const canGoBack = useSyncExternalStore(subscribe, () => router.history.canGoBack(), unavailable)
  const canGoForward = useSyncExternalStore(subscribe, browserCanGoForward, unavailable)
  const back = t('pod.sidebar.go_back')
  const forward = t('pod.sidebar.go_forward')
  return (
    <TopBarHistory aria-label={t('pod.sidebar.navigation_history')} className="max-md:hidden">
      <Button
        variant="ghost"
        size="icon-lg"
        aria-label={back}
        title={back}
        disabled={!canGoBack}
        onClick={() => router.history.back()}>
        <ChevronLeftRegular aria-hidden />
      </Button>
      <Button
        variant="ghost"
        size="icon-lg"
        aria-label={forward}
        title={forward}
        disabled={!canGoForward}
        onClick={() => router.history.forward()}>
        <ChevronRightRegular aria-hidden />
      </Button>
    </TopBarHistory>
  )
}

const unavailable = () => false

function browserCanGoForward() {
  return (globalThis as { navigation?: { canGoForward?: boolean } }).navigation?.canGoForward ?? true
}
