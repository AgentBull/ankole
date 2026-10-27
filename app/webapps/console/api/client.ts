import { identityHeaders } from '../../common/browser-context'
import { csrfToken } from '../../common/internal-api-client'
import { withDataContext } from '../../common/browser-session'
import { type Client } from './v2-site/generated/client'
import { client as siteV2Client } from './v2-site/generated/client.gen'
import { client as consoleV2Client } from './v2/generated/client.gen'
import { fromErrors, JSON_API_MEDIA_TYPE } from './json-api'

export function configureConsoleV2Client(v2Client: Pick<Client, 'setConfig' | 'interceptors'>): void {
  v2Client.setConfig({
    baseUrl: window.location.origin,
    credentials: 'same-origin',
    headers: { 'x-csrf-token': csrfToken(), ...identityHeaders(), accept: JSON_API_MEDIA_TYPE },
    fetch: withDataContext(globalThis.fetch)
  })
  v2Client.interceptors.error.use(fromErrors)
}

export function configureConsoleAPIClient(): void {
  // The v2 API is JSON:API. Its failures get the Console failure shape.
  for (const v2Client of [consoleV2Client, siteV2Client]) {
    configureConsoleV2Client(v2Client)
  }
}
