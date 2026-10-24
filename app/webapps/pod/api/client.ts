import { createClientConfig as browserConfig } from '../../common/internal-api-client'
import type { CreateClientConfig } from './generated/client.gen'

export const createClientConfig: CreateClientConfig = config => ({
  ...browserConfig(config),
  headers: { accept: 'application/vnd.api+json', 'content-type': 'application/vnd.api+json' }
})
