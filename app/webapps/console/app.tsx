import {
  RiLogoutBoxRLine,
  RiRefreshLine,
  RiRobot2Line,
  RiSettings3Line,
  RiSparkling2Line,
  RiBroadcastLine
} from '@remixicon/react'
import { Button } from '@ankole/uikit'
import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'
import type { ComponentType } from 'react'
import { useTranslation } from 'react-i18next'
import { configureConsoleApiClient, logoutConsoleSession } from './api/tokens'
import { AgentsWorkspace } from './workspaces/agents-workspace'
import { ProvidersWorkspace } from './workspaces/providers-workspace'
import { IdentityProvidersWorkspace } from './workspaces/identity-providers-workspace'
import { SignalsWorkspace } from './workspaces/signals-workspace'
import { AppConfigureWorkspace } from './workspaces/app-configure-workspace'

type Section = 'agents' | 'providers' | 'identity' | 'signals' | 'settings'

type NavItem = {
  id: Section
  label: string
  icon: ComponentType<{ className?: string }>
}

const NAV_ITEMS: NavItem[] = [
  { id: 'agents', label: 'console.nav.agents', icon: RiRobot2Line },
  { id: 'providers', label: 'console.nav.providers', icon: RiSparkling2Line },
  { id: 'identity', label: 'console.nav.identity', icon: RiSettings3Line },
  { id: 'signals', label: 'console.nav.signals', icon: RiBroadcastLine },
  { id: 'settings', label: 'console.nav.settings', icon: RiSettings3Line }
]

export function ConsoleApp() {
  useMemo(() => configureConsoleApiClient(), [])

  const { t } = useTranslation()
  const [section, setSection] = useState<Section>('agents')
  const queryClient = useQueryClient()
  const logout = useMutation({
    mutationFn: logoutConsoleSession,
    onSettled: () => window.location.assign('/sessions/new')
  })

  return (
    <main className="min-h-screen bg-background text-foreground">
      <header className="flex h-14 items-center justify-between border-b border-border px-4">
        <div className="flex min-w-0 items-center gap-3">
          <div className="grid size-9 place-items-center border border-border bg-muted">
            <RiSettings3Line className="size-4" aria-hidden />
          </div>
          <div className="min-w-0">
            <h1 className="truncate text-base font-semibold tracking-normal">{t('console.title')}</h1>
            <p className="truncate text-xs text-muted-foreground">{t('console.control_plane')}</p>
          </div>
        </div>
        <div className="flex items-center gap-2">
          <Button
            aria-label={t('console.aria.refresh')}
            size="icon-sm"
            type="button"
            variant="outline"
            onClick={() => void queryClient.invalidateQueries()}>
            <RiRefreshLine />
          </Button>
          <Button
            aria-label={t('console.aria.sign_out')}
            disabled={logout.isPending}
            size="icon-sm"
            type="button"
            variant="ghost"
            onClick={() => logout.mutate()}>
            <RiLogoutBoxRLine />
          </Button>
        </div>
      </header>

      <div className="grid min-h-[calc(100vh-3.5rem)] grid-cols-1 lg:grid-cols-[248px_minmax(0,1fr)]">
        <aside className="border-b border-border bg-muted/35 p-3 lg:border-r lg:border-b-0">
          <nav className="grid gap-1" aria-label={t('console.aria.sections')}>
            {NAV_ITEMS.map(item => {
              const Icon = item.icon
              const active = item.id === section
              return (
                <button
                  key={item.id}
                  className={
                    active
                      ? 'flex h-10 items-center gap-3 border border-primary bg-primary px-3 text-left text-sm text-primary-foreground'
                      : 'flex h-10 items-center gap-3 border border-transparent px-3 text-left text-sm text-muted-foreground hover:border-border hover:bg-background hover:text-foreground'
                  }
                  type="button"
                  onClick={() => setSection(item.id)}>
                  <Icon className="size-4" aria-hidden />
                  <span className="truncate">{t(item.label)}</span>
                </button>
              )
            })}
          </nav>
        </aside>

        <section className="min-w-0 p-4 md:p-6">
          {section === 'agents' ? <AgentsWorkspace /> : null}
          {section === 'providers' ? <ProvidersWorkspace /> : null}
          {section === 'identity' ? <IdentityProvidersWorkspace /> : null}
          {section === 'signals' ? <SignalsWorkspace /> : null}
          {section === 'settings' ? <AppConfigureWorkspace /> : null}
        </section>
      </div>
    </main>
  )
}
