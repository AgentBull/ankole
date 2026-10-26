/** This entry only declares types. Import it with `import type`. */
import type {
  AggregateQuery,
  AggregateResult,
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

export type RouteContext = {
  method: RouteMethod
  path: string
  params: RouteParams
  query: RouteQuery
  body: any
  principal: { uid: string; name?: string; kind: 'human' | 'agent' }
  applet: { pageId: string; revision: number }
  timezone: string
}
export type RouteHandler = (context: RouteContext) => unknown | Promise<unknown>
export type Routes = Partial<Record<Route, RouteHandler>>
export type FileEntry = { path: string; sha256: string; size: number; contentType: string | null }
export type FileRead = FileEntry & { bytes: Uint8Array }
export type FileWrite = { name: string; contentType?: string; bytes: Uint8Array; baseRevision?: number }
export type FileWriteResult = {
  name: string
  mime: string
  pageId: string
  revision: number
  path: string
  url?: string
  sha256: string
  size: number
  contentType: string | null
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
}
export type AnkoleRuntimeAPI = {
  HttpError: new (status: number, code: string, message?: string, details?: unknown) => HttpError
  base: {
    schema(tableId: string): Promise<TableSchema>
    query(tableId: string, query?: Omit<RecordQuery, 'local'>): Promise<RecordsResult>
    aggregate(tableId: string, query: AggregateQuery): Promise<AggregateResult>
    write(tableId: string, changes: RecordWrite): Promise<WriteResult>
  }
  file: {
    list(pageId: string): Promise<{ revision: number; files: FileEntry[] }>
    read(path: string): Promise<FileRead>
    write(pageId: string, file: FileWrite): Promise<FileWriteResult>
  }
  ai: { generateText(options: GenerateTextOptions): Promise<GenerateTextResult> }
}

declare global {
  const AnkoleRuntime: AnkoleRuntimeAPI
}
