import { identityHeaders } from '../../common/browser-context'
import { csrfToken } from '../../common/internal-api-client'
import { withDataContext } from '../../common/browser-session'
import { client } from './generated/client.gen'
import { client as siteV2Client } from './v2-site/generated/client.gen'
import { client as consoleV2Client } from './v2/generated/client.gen'
import { fromErrors, JSON_API_MEDIA_TYPE } from './json-api'

export function configureConsoleAPIClient(): void {
  const config = {
    baseUrl: window.location.origin,
    credentials: 'same-origin' as const,
    headers: { 'x-csrf-token': csrfToken(), ...identityHeaders() },
    fetch: withDataContext(globalThis.fetch)
  }
  client.setConfig(config)

  // The v2 API is JSON:API. Its failures get the Console failure shape.
  for (const v2Client of [consoleV2Client, siteV2Client]) {
    v2Client.setConfig({ ...config, headers: { ...config.headers, accept: JSON_API_MEDIA_TYPE } })
    v2Client.interceptors.error.use(fromErrors)
  }
}
