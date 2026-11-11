import { Button, Tooltip, TooltipContent, TooltipProvider, TooltipTrigger, useTheme } from '@ankole/uikit'
import { WeatherMoonRegular, WeatherSunnyRegular } from '@ankole/uikit/icons'
import { useTranslation } from 'react-i18next'

/** Switches the shared Ankole theme while keeping the current surface intact. */
export function ThemeToggle({ className }: { className?: string }) {
  const { resolvedTheme, setTheme } = useTheme()
  const { t } = useTranslation()
  const dark = resolvedTheme === 'dark'
  const label = dark ? t('common.theme_light') : t('common.theme_dark')

  return (
    <TooltipProvider>
      <Tooltip>
        <TooltipTrigger
          render={<Button aria-label={label} className={className} size="icon-sm" type="button" variant="ghost" />}
          onClick={() => setTheme(dark ? 'light' : 'dark')}>
          {dark ? (
            <WeatherSunnyRegular
              key="sun"
              aria-hidden
              className="size-4 motion-safe:[animation:theme-mark_180ms_var(--ease-productive)]"
            />
          ) : (
            <WeatherMoonRegular
              key="moon"
              aria-hidden
              className="size-4 motion-safe:[animation:theme-mark_180ms_var(--ease-productive)]"
            />
          )}
        </TooltipTrigger>
        <TooltipContent>{label}</TooltipContent>
      </Tooltip>
    </TooltipProvider>
  )
}
