/** This entry only declares types. Import it with `import type`. */
import type {
  ActionRun,
  AggregateQuery,
  AggregateResult,
  MetricQueryOptions,
  MetricResult,
  RecordQuery,
  RecordsResult,
  RecordWrite,
  Route,
  RouteMethod,
  RouteParams,
  RouteQuery,
  TableSchema,
  WriteResult
} from './types'
export type { ActionRun, MetricQueryOptions, MetricResult } from './types'

export type RouteContext = {
  method: RouteMethod
  path: string
  params: RouteParams
  query: RouteQuery
  body: any
  principal: { uid: string; name?: string; kind: 'human' | 'agent' }
  applet: { pageId: string; revision: number }
  timezone: string
  remainingMs(): number
}
export type RouteHandler = (request: RouteContext, context: RouteContext) => unknown | Promise<unknown>
export type Routes = Partial<Record<Route, RouteHandler>>
export type FileEntry = {
  path: string
  objectId: string
  sha256: string
  size: number
  contentType: string | null
}
export type FileRead = FileEntry & { bytes: Uint8Array }
export type FileWrite = {
  name: string
  contentType?: string
  bytes: Uint8Array
  baseObjectId?: string | null
}
export type FileWriteResult = FileEntry & {
  name: string
  mime: string
  pageId: string
  revision: number
  url?: string
}
export type GenerateTextOptions = {
  model: string
  effort?: 'none' | 'minimal' | 'low' | 'medium' | 'high' | 'xhigh' | 'max' | 'ultra'
  system?: string
  prompt: string
}
export type GenerateTextResult = {
  text: string
  finishReason: 'stop' | 'length'
  usage: { inputTokens: number; outputTokens: number }
}
export interface HttpError extends Error {
  status: number
  code: string
  details?: unknown
  retryable?: boolean
  request_sent?: boolean
}
export type RuntimeCapabilities = {
  base: {
    schema(tableId: string): Promise<TableSchema>
    query(tableId: string, query?: Omit<RecordQuery, 'local'>): Promise<RecordsResult>
    aggregate(tableId: string, query: AggregateQuery): Promise<AggregateResult>
    write(tableId: string, changes: RecordWrite): Promise<WriteResult>
  }
  /** Executes a published Brain metric (`metrics/<name>` or object ID) without a model; GET routes may call it. */
  metrics: { query(metric: string, options?: MetricQueryOptions): Promise<MetricResult> }
  file: {
    list(pageId: string): Promise<{ revision: number; files: FileEntry[] }>
    read(path: string): Promise<FileRead>
    write(pageId: string, file: FileWrite): Promise<FileWriteResult>
  }
  ai: { generateText(options: GenerateTextOptions): Promise<GenerateTextResult> }
  mcp: {
    call<T = unknown>(
      tool: string,
      args: Record<string, unknown>,
      options: { server: string; connection?: string; account?: string; skill?: string }
    ): Promise<T>
  }
  signals: {
    call<T = unknown>(request: {
      actionKey: string
      data?: Record<string, unknown>
      responseMode?: 'wait_result'
    }): Promise<T>
    emit(request: {
      targetJobId: number
      id?: string
      subject?: string
      type: string
      data?: Record<string, unknown>
      responseMode?: 'wait_accepted'
    }): Promise<{ accepted: true; runId: number; coalesced: boolean }>
    emit(request: {
      id?: string
      subject?: string
      type: string
      data?: Record<string, unknown>
      responseMode?: 'fire_and_forget'
    }): Promise<{ accepted: true; signalId: string }>
    run(runId: number): Promise<ActionRun>
  }
}

export type AnkoleRuntimeAPI = RuntimeCapabilities & {
  HttpError: new (status: number, code: string, message?: string, details?: unknown) => HttpError
  admin: RuntimeCapabilities
}
export type StateScope = {
  get<T = unknown>(key: string): Promise<T | null>
  set(key: string, value: unknown): Promise<void>
  delete(key: string): Promise<void>
}
export type ActionContext = {
  principal: RouteContext['principal'] | null
  applet: RouteContext['applet']
  timezone: string
  signal: { id: string; type: string; data: Record<string, any> }
  job: { id: number; config: Record<string, any> }
  run: { id: number; attemptId: string; sliceCount: number; progress: Record<string, unknown> }
  state: StateScope & { scope(name: string): StateScope }
  remainingMs(): number
  continueSlice(options?: { delaySeconds?: number; progress?: Record<string, unknown> }): Promise<unknown>
}
export type Action = {
  idempotent: boolean
  concurrency?: 'parallel' | 'serial_fifo' | 'serial_coalesce'
  concurrencyKey?: (context: Pick<ActionContext, 'job' | 'signal'>) => string
  maxSlices?: number
  handler(context: ActionContext): unknown | Promise<unknown>
}
export type Applet = { routes?: Routes; actions?: Record<string, Action> }

declare global {
  const AnkoleRuntime: AnkoleRuntimeAPI
}
