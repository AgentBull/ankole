import * as React from 'react'

export type SidebarContextProps = {
  state: 'expanded' | 'collapsed'
  open: boolean
  setOpen: (open: boolean) => void
  openMobile: boolean
  setOpenMobile: (open: boolean) => void
  isMobile: boolean
  toggleSidebar: () => void
}

/**
 * The state that `SidebarProvider` shares with the sidebar and the shell around it. A component that may render
 * outside a provider, such as the top bar, reads this context directly and treats `null` as "no sidebar".
 */
export const SidebarContext = React.createContext<SidebarContextProps | null>(null)

export function useSidebar() {
  const context = React.useContext(SidebarContext)
  if (!context) {
    throw new Error('useSidebar must be used within a SidebarProvider.')
  }

  return context
}
