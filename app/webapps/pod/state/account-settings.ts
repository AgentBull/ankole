import { createModel, signal } from '@preact/signals-react'

export const AccountSettingsModel = createModel(() => ({
  displayName: signal<string>(),
  confirmUnbind: signal<string>(),
  email: signal(''),
  challengeID: signal<string>(),
  code: signal(''),
  confirmExit: signal(false)
}))
