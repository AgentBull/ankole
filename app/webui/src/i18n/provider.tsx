import type { ReactNode } from 'react'
import { I18nextProvider } from 'react-i18next'
import i18n from './i18n'

export function BullXI18nextProvider({ children }: { children: ReactNode }) {
  return <I18nextProvider i18n={i18n}>{children}</I18nextProvider>
}
