import { Button, Tooltip, TooltipContent, TooltipProvider, TooltipTrigger, useTheme } from '@ankole/uikit'
import { RiMoonLine, RiSunLine } from '@remixicon/react'
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
          {dark ? <RiSunLine aria-hidden /> : <RiMoonLine aria-hidden />}
        </TooltipTrigger>
        <TooltipContent>{label}</TooltipContent>
      </Tooltip>
    </TooltipProvider>
  )
}
