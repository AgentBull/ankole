import { csrfToken, internalAPIDelete } from '../../common/internal-api-client'
import { clearDataTenant, withDataContext } from './data-context'
import { client } from './generated/client.gen'

export function configureConsoleAPIClient(): void {
  client.setConfig({
    baseUrl: window.location.origin,
    credentials: 'same-origin',
    headers: { 'x-csrf-token': csrfToken() },
    fetch: withDataContext(globalThis.fetch)
  })
}

export async function logoutConsoleSession(): Promise<void> {
  clearDataTenant()
  await internalAPIDelete('/.internal-apis/session')
}
