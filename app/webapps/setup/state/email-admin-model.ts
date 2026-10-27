import { createModel, signal } from '@preact/signals-react'
import type { RequestSetupEmailOtpResponse } from '../../common/api/generated/types.gen'

export const EmailAdminModel = createModel(() => {
  const code = signal('')
  const challenge = signal<RequestSetupEmailOtpResponse>()
  return {
    displayName: signal(''),
    email: signal(''),
    code,
    challenge,
    server: signal(''),
    port: signal('587'),
    from: signal(''),
    username: signal(''),
    password: signal(''),
    ssl: signal(false),
    receiveChallenge(next: RequestSetupEmailOtpResponse) {
      challenge.value = next
      code.value = ''
    },
    editMail() {
      challenge.value = undefined
      code.value = ''
    }
  }
})
