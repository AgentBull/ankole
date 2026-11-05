import { ThemeProvider as NextThemeProvider, useTheme as useNextTheme, type UseThemeProps } from 'next-themes'
import { useCallback, useMemo, useSyncExternalStore, type ComponentProps } from 'react'

function readDocumentTheme(): 'light' | 'dark' {
  if (typeof document === 'undefined') return 'light'
  return document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light'
}

function subscribeDocumentTheme(onStoreChange: () => void): () => void {
  if (typeof document === 'undefined' || typeof MutationObserver === 'undefined') return () => {}
  const observer = new MutationObserver(onStoreChange)
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] })
  return () => observer.disconnect()
}

const noopSubscribe = () => () => {}
const serverTheme = (): 'light' | 'dark' => 'light'

function ThemeProvider({ children, ...props }: ComponentProps<typeof NextThemeProvider>) {
  return (
    <NextThemeProvider
      attribute="data-theme"
      defaultTheme="light"
      disableTransitionOnChange
      enableColorScheme
      enableSystem={false}
      storageKey="ankole-theme"
      themes={['light', 'dark']}
      {...props}>
      {children}
    </NextThemeProvider>
  )
}

function useTheme(): UseThemeProps {
  const context = useNextTheme()
  const hasProvider = context.themes.length > 0
  const subscribe = useCallback(
    (onStoreChange: () => void) => (hasProvider ? noopSubscribe() : subscribeDocumentTheme(onStoreChange)),
    [hasProvider]
  )
  const documentTheme = useSyncExternalStore(subscribe, readDocumentTheme, serverTheme)
  return useMemo(
    () =>
      hasProvider
        ? context
        : {
            theme: documentTheme,
            resolvedTheme: documentTheme,
            forcedTheme: documentTheme,
            themes: ['light', 'dark'],
            setTheme: context.setTheme
          },
    [hasProvider, context, documentTheme]
  )
}

export { ThemeProvider, useTheme }
