import { useTheme } from 'next-themes'
import { Toaster as Sonner, toast, type ToasterProps } from 'sonner'
import {
  RiCheckboxCircleLine,
  RiInformationLine,
  RiErrorWarningLine,
  RiCloseCircleLine,
  RiLoaderLine
} from '@remixicon/react'

const Toaster = ({ ...props }: ToasterProps) => {
  const { theme = 'system' } = useTheme()

  return (
    <Sonner
      theme={theme as ToasterProps['theme']}
      className="toaster group"
      // Keep bottom notifications above the fixed footer actions.
      offset={{ bottom: 'calc(5rem + env(safe-area-inset-bottom, 0px))' }}
      mobileOffset={{ bottom: 'calc(5rem + env(safe-area-inset-bottom, 0px))' }}
      icons={{
        success: <RiCheckboxCircleLine className="size-4" />,
        info: <RiInformationLine className="size-4" />,
        warning: <RiErrorWarningLine className="size-4" />,
        error: <RiCloseCircleLine className="size-4" />,
        loading: <RiLoaderLine className="size-4 animate-spin" />
      }}
      style={
        {
          '--normal-bg': 'var(--popover)',
          '--normal-text': 'var(--popover-foreground)',
          '--normal-border': 'var(--border)'
        } as React.CSSProperties
      }
      toastOptions={{
        classNames: {
          toast: 'cn-toast'
        }
      }}
      {...props}
    />
  )
}

export { Toaster, toast }
