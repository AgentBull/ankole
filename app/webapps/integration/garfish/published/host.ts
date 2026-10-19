/** Real publisher and host; HTTP responses are supplied by the browser test. */
import { QueryClient } from '@tanstack/react-query'
import { mountApplet } from '../../../pod/applet-host'
import { createDatabaseAPI } from '../../../pod/database-api'
import { podRequest } from '../../../pod/content-api'
import { PodRealtime } from '../../../pod/realtime'
import { loadLocale } from '../../../common/i18n'

await loadLocale('en-US')
const client = new QueryClient()
const realtime = new PodRealtime()
const status = document.querySelector('#status')!
const unmount = mountApplet(
  'publication-fixture',
  'browser',
  document.querySelector('#applet')!,
  {
    pageID: 'publication-fixture',
    instanceID: 'browser',
    queryClient: client,
    database: createDatabaseAPI(client, realtime),
    pod: { request: podRequest },
    channel: name => realtime.channel('publication-fixture', name)
  },
  error => {
    status.textContent = `error:${(error as { status?: number }).status ?? String(error)}`
  },
  () => {
    status.textContent = 'ready'
  }
)
window.addEventListener('pagehide', unmount, { once: true })
