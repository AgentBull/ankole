import { RiMoonLine, RiSunLine } from '@remixicon/react'
import { useEffect, useState } from 'react'

type Theme = 'light' | 'dark'

const STORAGE_KEY = 'ankole-theme'

/**
 * Dark is the product default. The toggle does not follow the operating system, because
 * the dark surface is the identity rather than a preference mirror; light is opt-in and
 * survives in local storage once chosen.
 */
const DEFAULT_THEME: Theme = 'dark'

function getStoredTheme(): Theme | null {
  try {
    const value = window.localStorage.getItem(STORAGE_KEY)
    return value === 'dark' || value === 'light' ? value : null
  } catch {
    return null
  }
}

interface ThemeToggleProps {
  /** aria-label shown when the current theme is dark (click switches to light). */
  labelLight: string
  /** aria-label shown when the current theme is light (click switches to dark). */
  labelDark: string
}

export default function ThemeToggle({ labelLight, labelDark }: ThemeToggleProps) {
  const [resolved, setResolved] = useState<Theme>(DEFAULT_THEME)

  useEffect(() => {
    setResolved(getStoredTheme() ?? DEFAULT_THEME)
  }, [])

  useEffect(() => {
    document.documentElement.dataset.theme = resolved
  }, [resolved])

  const toggle = () => {
    const next: Theme = resolved === 'dark' ? 'light' : 'dark'
    try {
      window.localStorage.setItem(STORAGE_KEY, next)
    } catch {
      // Private browsing may deny storage; the toggle still applies for this page.
    }
    setResolved(next)
  }

  const label = resolved === 'dark' ? labelLight : labelDark
  const Icon = resolved === 'dark' ? RiSunLine : RiMoonLine

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={label}
      title={label}
      className="inline-flex size-9 cursor-pointer items-center justify-center text-muted-foreground transition-colors duration-150 ease-[var(--ease-productive)] hover:bg-muted hover:text-foreground">
      {/* Keyed so the swapped mark replays its turn-in: the click gets an answer. */}
      <Icon key={resolved} className="size-5 [animation:theme-mark_180ms_var(--ease-productive)]" />
    </button>
  )
}
