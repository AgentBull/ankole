import { SidebarTrigger, useSidebar } from '@ankole/uikit'
import { RiSearchLine } from '@remixicon/react'
import { createContext, use, useCallback, useLayoutEffect, useMemo, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'
import { useTranslation } from 'react-i18next'
import { Link } from '@tanstack/react-router'
import { useQuery } from '@tanstack/react-query'
import { browserSession } from '../common/api/generated/sdk.gen'
import { authenticationRef, podID, podLocation } from '../common/browser-context'
import { isApplePlatform } from '../common/platform'
import { SpaceMark, sessionAvatarContext } from './account-menu'
import { usePodCommandMenu } from './command-menu'

type TopBarSlot = {
  target: HTMLElement | null
  setTarget(node: HTMLElement | null): void
  /** How many sheet headers on screen carry the sidebar toggle. */
  toggles: number
  /** Registers a sheet header's toggle and returns the function that releases it. */
  claimToggle(): () => void
}

const PodTopBarContext = createContext<TopBarSlot>({
  target: null,
  setTarget: () => {},
  toggles: 0,
  claimToggle: () => () => {}
})

/** Shares the top bar's action slot, and the placement of the sidebar toggle, with the routes rendered below it. */
export function PodTopBarProvider({ children }: { children: ReactNode }) {
  const [target, setTarget] = useState<HTMLElement | null>(null)
  const [toggles, setToggles] = useState(0)
  const claimToggle = useCallback(() => {
    setToggles(count => count + 1)
    return () => setToggles(count => count - 1)
  }, [])
  const value = useMemo(() => ({ target, setTarget, toggles, claimToggle }), [target, toggles, claimToggle])
  return <PodTopBarContext value={value}>{children}</PodTopBarContext>
}

/**
 * The Pod shell's top bar spans the window above the sidebar and the content sheets. It carries the Pod's mark and name at its
 * start, the search entry in its centre and, at its end, the actions that the open route places through `PodTopBarActions`. The sidebar toggle
 * sits left of the sheet's title; only a route whose sheet has no header leaves the toggle at the top bar's start.
 */
export function PodTopBar() {
  const { t } = useTranslation()
  const { setTarget, toggles } = use(PodTopBarContext)
  const openCommand = usePodCommandMenu()
  const shortcut = isApplePlatform() ? '⌘K' : 'Ctrl+K'
  const label = t('pod.command.open')

  return (
    <header className="@container flex h-(--pod-top-bar-height) shrink-0 items-center gap-2 px-3">
      <div className="flex min-w-0 flex-[1_0_0] items-center gap-2">
        <PodBrand />
        {toggles === 0 && <SidebarToggleButton />}
      </div>
      {/* A quiet, borderless field: it names the command and its shortcut without competing with the sheets below,
          and on a narrow top bar it becomes an icon button. */}
      <button
        type="button"
        className="flex h-7 min-w-7 flex-[0_1_15rem] cursor-pointer items-center gap-1.5 rounded-control bg-field px-2 text-xs text-fg-tertiary transition-colors hover:bg-field-hover hover:text-fg-secondary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-ring @max-[720px]:flex-none @max-[720px]:justify-center @max-[720px]:bg-transparent @max-[720px]:px-0 @max-[720px]:hover:bg-accent"
        aria-label={label}
        aria-keyshortcuts="Meta+K Control+K"
        title={`${label} (${shortcut})`}
        onClick={openCommand}>
        <RiSearchLine aria-hidden className="size-3.5 shrink-0 @max-[720px]:size-4" />
        <span className="min-w-0 flex-1 truncate text-left @max-[720px]:hidden">{label}</span>
        <span aria-hidden className="shrink-0 font-mono text-[11px] text-fg-placeholder @max-[720px]:hidden">
          {shortcut}
        </span>
      </button>
      {/* The ends grow equally so the search entry stays centred; when the route's actions need more room, the
          search entry narrows first. */}
      <div ref={setTarget} className="flex flex-[1_0_0] items-center justify-end" />
    </header>
  )
}

/** Renders the open route's actions at the end of the shell's top bar. */
export function PodTopBarActions({ children }: { children: ReactNode }) {
  const { target } = use(PodTopBarContext)
  return target ? createPortal(children, target) : null
}

/** The sidebar toggle at the start of a sheet header, left of the sheet's title. */
export function PodSidebarToggle() {
  const { claimToggle } = use(PodTopBarContext)
  useLayoutEffect(() => claimToggle(), [claimToggle])
  return <SidebarToggleButton />
}

/** The Pod's mark and name, the same pair that the account menu shows, linking to the Pod's chat home. */
function PodBrand() {
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
      className="flex min-w-0 items-center gap-2 rounded-control py-1 pr-1.5 text-[13px] font-semibold text-foreground no-underline">
      <SpaceMark name={name} avatarURL={session.data?.tenant?.avatarURL} context={sessionAvatarContext(session.data)} />
      <span className="truncate max-sm:hidden">{name}</span>
    </Link>
  )
}

function SidebarToggleButton() {
  const { t } = useTranslation()
  const { state, isMobile } = useSidebar()
  return (
    <SidebarTrigger label={state === 'expanded' && !isMobile ? t('pod.sidebar.collapse') : t('pod.sidebar.expand')} />
  )
}
