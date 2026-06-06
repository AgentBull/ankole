import { rootContainer } from '@/common/di'
import { ExternalGatewayRuntime } from './runtime'

export * from './adapter-registry'
export * from './agent'
export * from './agent-events'
export * from './config'
export * from './core/projection'
export * from './handlers'
export * from './metadata'
export * from './outbox'
export * from './routes'
export * from './runtime'

export const externalGatewayRuntime = rootContainer.resolve(ExternalGatewayRuntime)
