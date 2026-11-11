import * as React from 'react'

const MOBILE_BREAKPOINT = 768

/**
 * Whether the window is narrower than `breakpoint`. The first render already reads the window, so a phone never
 * renders the desktop layout first and then animates into its own.
 */
export function useIsMobile(breakpoint = MOBILE_BREAKPOINT) {
  const [isMobile, setIsMobile] = React.useState<boolean | undefined>(() =>
    typeof window === 'undefined' ? undefined : window.innerWidth < breakpoint
  )

  React.useEffect(() => {
    const mql = window.matchMedia(`(max-width: ${breakpoint - 1}px)`)
    const onChange = () => {
      setIsMobile(window.innerWidth < breakpoint)
    }
    mql.addEventListener('change', onChange)
    setIsMobile(window.innerWidth < breakpoint)
    return () => mql.removeEventListener('change', onChange)
  }, [breakpoint])

  return !!isMobile
}
