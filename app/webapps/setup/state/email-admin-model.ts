import { createModel, signal } from '@preact/signals-react'

export const EmailAdminModel = createModel(() => ({
  displayName: signal(''),
  email: signal(''),
  code: signal(''),
  server: signal(''),
  port: signal('587'),
  from: signal(''),
  username: signal(''),
  password: signal(''),
  ssl: signal(false)
}))
