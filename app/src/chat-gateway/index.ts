import { rootContainer } from '@/common/di'
import { ChatGatewayRuntime } from './runtime'

export * from './adapter-registry'
export * from './config'
export * from './core/echo-text'
export * from './core/message-lifecycle'
export * from './core/projection'
export * from './metadata'
export * from './routes'
export * from './runtime'
export * from './core/state-postgres'

export const chatGatewayRuntime = rootContainer.resolve(ChatGatewayRuntime)
