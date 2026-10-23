import type { ListWorkerProviderKindsResponse } from './v2-site/generated/types.gen'
import type {
  ListAppConfigurationsResponse,
  UpdateAppConfigurationData,
  ListWorkerEnvsResponse
} from './v2/generated/types.gen'

export type AppConfigurationItem = ListAppConfigurationsResponse['app_configurations'][number]
export type AppConfigurationUpdateRequest = NonNullable<UpdateAppConfigurationData['body']>['data']
export type WorkerEnvItem = ListWorkerEnvsResponse['worker_envs'][number]
export type JsonValue = unknown

export type WorkerProviderKind = ListWorkerProviderKindsResponse['worker_provider_kinds'][number]
