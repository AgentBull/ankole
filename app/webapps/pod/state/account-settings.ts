import { createModel, signal } from '@preact/signals-react'

export const AccountSettingsModel = createModel(() => ({
  email: signal(''),
  code: signal(''),
  confirmExit: signal(false)
}))
