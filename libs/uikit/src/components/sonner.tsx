import { useTheme } from './theme-provider'
import { Spinner } from './spinner'
import { Toaster as Sonner, toast, type ToasterProps } from 'sonner'
import { CheckmarkCircleRegular, DismissCircleRegular, ErrorCircleRegular, InfoRegular } from '../icons'

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
        success: <CheckmarkCircleRegular className="size-4" />,
        info: <InfoRegular className="size-4" />,
        warning: <ErrorCircleRegular className="size-4" />,
        error: <DismissCircleRegular className="size-4" />,
        loading: <Spinner aria-hidden className="size-4" />
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
