import { RiMoonLine, RiSunLine } from '@remixicon/react'
import { useEffect, useState } from 'react'

type Theme = 'light' | 'dark'

const STORAGE_KEY = 'ankole-theme'

function getStoredTheme(): Theme | null {
  try {
    const value = window.localStorage.getItem(STORAGE_KEY)
    return value === 'dark' || value === 'light' ? value : null
  } catch {
    return null
  }
}

function getSystemTheme(): Theme {
  return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'
}

interface ThemeToggleProps {
  /** aria-label shown when the current theme is dark (click switches to light). */
  labelLight: string
  /** aria-label shown when the current theme is light (click switches to dark). */
  labelDark: string
}

export default function ThemeToggle({ labelLight, labelDark }: ThemeToggleProps) {
  const [stored, setStored] = useState<Theme | null>(null)
  const [resolved, setResolved] = useState<Theme>('light')

  useEffect(() => {
    const initial = getStoredTheme()
    setStored(initial)
    setResolved(initial ?? getSystemTheme())
  }, [])

  useEffect(() => {
    document.documentElement.dataset.theme = resolved
  }, [resolved])

  // Follow the system theme while the user has not made an explicit choice.
  useEffect(() => {
    if (stored) return
    const mq = window.matchMedia('(prefers-color-scheme: dark)')
    const handler = (event: MediaQueryListEvent) => setResolved(event.matches ? 'dark' : 'light')
    mq.addEventListener('change', handler)
    return () => mq.removeEventListener('change', handler)
  }, [stored])

  const toggle = () => {
    const next: Theme = resolved === 'dark' ? 'light' : 'dark'
    try {
      window.localStorage.setItem(STORAGE_KEY, next)
    } catch {
      // Private browsing may deny storage; the toggle still applies for this page.
    }
    setStored(next)
    setResolved(next)
  }

  const label = resolved === 'dark' ? labelLight : labelDark

  return (
    <button
      type="button"
      onClick={toggle}
      aria-label={label}
      title={label}
      className="inline-flex size-9 cursor-pointer items-center justify-center text-muted-foreground transition-colors hover:bg-muted hover:text-foreground">
      {resolved === 'dark' ? <RiSunLine className="size-5" /> : <RiMoonLine className="size-5" />}
    </button>
  )
}
