import { rootContainer } from '@/common/di'
import { ChatGatewayRuntime } from './runtime'

export * from './adapter-registry'
export * from './config'
export * from './metadata'
export * from './projection'
export * from './routes'
export * from './runtime'
export * from './state-postgres'

export const chatGatewayRuntime = rootContainer.resolve(ChatGatewayRuntime)
