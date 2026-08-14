import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { ThemeToggle } from '../common/theme-toggle'
import logoDark from './logo-dark.svg'
import backgroundImageURL from './marjan-taghipour-0fof1Z4CwQo-unsplash.jpg'

/** Provides the visual frame for the setup-only SPA. */
export function SetupLayout({ children }: { children: ReactNode }) {
  const { t } = useTranslation()
  return (
    <main
      className="relative isolate min-h-screen bg-background bg-cover bg-center bg-no-repeat text-foreground"
      style={{ backgroundImage: `url(${backgroundImageURL})` }}>
      <div className="absolute inset-0 -z-10 bg-background/94" aria-hidden="true" />
      <div className="mx-auto flex min-h-screen w-full max-w-6xl flex-col px-4 py-5 sm:px-6 lg:px-8">
        <header className="flex h-12 shrink-0 items-center justify-between gap-3 border-b border-border">
          <div className="flex min-w-0 items-center gap-3">
            <span className="flex size-8 shrink-0 items-center justify-center bg-gray-80">
              <img src={logoDark} className="size-5" alt="" />
            </span>
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold">Ankole</p>
              <p className="truncate text-xs text-muted-foreground">{t('setup.product_label')}</p>
            </div>
          </div>
          <ThemeToggle />
        </header>
        {children}
      </div>
    </main>
  )
}
