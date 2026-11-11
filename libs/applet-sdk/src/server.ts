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
export type WebSearchOptions = {
  query: string
  limit?: number
}
export type WebSearchResultItem = {
  title: string
  url: string
  snippet: string
  position?: number
  publishedAt?: string | null
  score?: number | null
}
export type WebSearchResult = {
  query: string
  results: WebSearchResultItem[]
}
export type WebFetchOptions = {
  urls: string[]
  maxChars?: number
}
export type WebFetchPage = {
  url: string
  title?: string
  text?: string
  truncated?: boolean
  renderWarning?: 'empty_text' | 'script_shell' | null
  error?: string
}
export type WebFetchResult = {
  success: boolean
  results: WebFetchPage[]
}
export type GenerateImageOptions = {
  prompt: string
  action?: 'generate' | 'edit' | 'auto'
  images?: string[]
  mask?: string
  size?: 'auto' | `${number}x${number}`
  quality?: 'low' | 'medium' | 'high' | 'auto'
  background?: 'transparent' | 'opaque' | 'auto'
  outputFormat?: 'png' | 'webp' | 'jpeg'
  outputCompression?: number
  moderation?: 'auto' | 'low'
  inputFidelity?: 'low' | 'high'
  saveTo?: {
    pageId: string
    name?: string
  }
}
export type GenerateImageResult = {
  url: string
  mimeType: 'image/png' | 'image/jpeg' | 'image/webp' | 'image/gif'
  revisedPrompt?: string | null
  file: FileEntry & {
    name: string
    mime: string
    pageId: string
  }
  usage?: {
    inputTokens?: number
    outputTokens?: number
    totalTokens?: number
  }
}
export interface HttpError extends Error {
  status: number
  code: string
  details?: unknown
  retryable?: boolean
  request_sent?: boolean
}
export type ApprovalDecision = 'approved' | 'rejected'
export type ApprovalRequest = {
  requestKey: string
  reviewerUid: string
  summary: string
  details?: string
}
export type Approval = {
  id: string
  requestKey: string
  requesterUid: string
  reviewerUid: string
  summary: string
  details: string | null
  status: 'pending' | ApprovalDecision
  requestedAt: string
  decidedAt: string | null
  note: string | null
}
export type TakeScope = {
  sourceNodeId: string
  subjectPageId?: string
}
export type TakeFilter = TakeScope & {
  holderUid?: string
  kind?: string
}
export type FactNotability = 'high' | 'medium' | 'low'
export type FactFilter = TakeScope & {
  holderUid?: string
  kind?: 'event' | 'preference' | 'commitment' | 'belief' | 'fact' | (string & {})
  notability?: FactNotability | FactNotability[]
  query?: string
}
export type TakeInput = TakeScope & {
  claim: string
  kind: string
  weight: number
  sinceDate?: string
  untilDate?: string
  provenance: string
}
export type Take = {
  id: string
  sourceNodeId: string
  subjectPageId: string | null
  holder: string
  holderUid: string | null
  author: string | { tenant_id: string; uid: string } | null
  claim: string
  kind: string
  weight: number
  active: boolean
  sinceDate: string | null
  untilDate: string | null
  provenance: string
  createdAt: string
  resolvedAt: string | null
  resolvedQuality: string | null
  resolvedOutcome: boolean | null
  resolutionProvenance: string | null
  supersededBy: string | null
}
export type Fact = {
  id: string
  sourceNodeId: string
  subjectPageId: string | null
  holder: string
  holderUid: string | null
  author: string | { tenant_id: string; uid: string } | null
  claim: string
  kind: string
  notability: string | null
  confidence: number | null
  context: string | null
  validFrom: string | null
  validUntil: string | null
  provenance: string
  createdAt: string
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
  brain: {
    listTakes(options: TakeFilter & { limit?: number }): Promise<{ takes: Take[] }>
    listFacts(options: FactFilter & { limit?: number }): Promise<{ facts: Fact[] }>
    writeTake(options: TakeInput): Promise<Take>
    calibration(options: TakeFilter & { domain?: string }): Promise<{ resolvedCount: number; brier: number | null }>
  }
  notifications: {
    /** Posts to an existing native conversation using a stable message UUIDv7. */
    post(request: { conversationId: string; messageId: string; text: string }): Promise<{
      conversationId: string
      messageId: string
    }>
  }
  approvals: {
    request(request: ApprovalRequest): Promise<Approval>
    get(id: string): Promise<Approval>
    list(): Promise<{ approvals: Approval[] }>
  }
  file: {
    list(pageId: string): Promise<{ revision: number; files: FileEntry[] }>
    /** Pin to the lowercase SHA-256 from the manifest; a changed file returns `manifest_changed`. */
    read(path: string, options?: { sha256?: string }): Promise<FileRead>
    write(pageId: string, file: FileWrite): Promise<FileWriteResult>
  }
  ai: {
    generateText(options: GenerateTextOptions): Promise<GenerateTextResult>
    generateImage(options: GenerateImageOptions): Promise<GenerateImageResult>
  }
  web: {
    search(options: WebSearchOptions): Promise<WebSearchResult>
    fetch(options: WebFetchOptions): Promise<WebFetchResult>
  }
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
    }): Promise<{ accepted: true; signalId: string; delivered: boolean }>
    run(runId: number): Promise<ActionRun>
  }
}

export type AnkoleRuntimeAPI = RuntimeCapabilities & {
  approvals: RuntimeCapabilities['approvals'] & {
    /** The assigned reviewer decides through a signed-in browser mutation route. */
    decide(request: { id: string; decision: ApprovalDecision; note?: string }): Promise<Approval>
  }
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
