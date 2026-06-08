/**
 * `@agentbull/bullx-computer` — Vercel-like TypeScript SDK for the BullX Computer.
 *
 * ```ts
 * import { Computer } from '@agentbull/bullx-computer'
 * const computer = await Computer.getOrCreate({ agentUid: 'agent_123' })
 * const result = await computer.runCommand('python', ['temp/hello.py'])
 * console.log(result.exitCode, await result.stdout())
 * ```
 */

export { COMPUTER_SDK_VERSION } from './version'

export { Computer } from './computer'
export type { GetOrCreateComputerParams, GetComputerParams, ComputerConnectionConfig } from './computer'

export { Command, CommandFinished } from './command'
export { FileSystem } from './filesystem'
export type { DownloadTarget, ReadFileRef } from './filesystem'
export { TerminalManager } from './terminal'

export { ApiError, isApiError } from './api-client/api-error'
export { BaseClient } from './api-client/base-client'
export type { BaseClientConfig, RequestOptions } from './api-client/base-client'
export { ControlClient } from './api-client/control-client'
export { WorkerClient } from './api-client/worker-client'
export { FileWriter } from './api-client/file-writer'

export * from './types'
