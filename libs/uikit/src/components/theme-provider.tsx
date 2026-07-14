import { ThemeProvider as NextThemeProvider, useTheme } from 'next-themes'
import type { ComponentProps } from 'react'

/** Applies one installation-wide light/dark theme contract through `data-theme`. */
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

export { ThemeProvider, useTheme }
