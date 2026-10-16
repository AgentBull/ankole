import { identityHeaders } from '../../common/browser-context'
import { csrfToken } from '../../common/internal-api-client'
import { withDataContext } from '../../common/browser-session'
import { client } from './generated/client.gen'

export function configureConsoleAPIClient(): void {
  client.setConfig({
    baseUrl: window.location.origin,
    credentials: 'same-origin',
    headers: { 'x-csrf-token': csrfToken(), ...identityHeaders() },
    fetch: withDataContext(globalThis.fetch)
  })
}
