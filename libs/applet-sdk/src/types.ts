import type { Query, QueryClient } from '@tanstack/react-query'

export type Value = string | number | boolean | null | unknown[] | Record<string, unknown>
export type RecordData = Record<string, Value>
export type Versions = Record<string, number>
export type BaseRecord = {
  id: string
  data: RecordData
  versions: Versions
  created_at: string
  updated_at: string
  created_by: string
  updated_by: string
}
export type FieldType =
  | 'text'
  | 'number'
  | 'select'
  | 'datetime'
  | 'checkbox'
  | 'user'
  | 'attachment'
  | 'auto_number'
  | 'link'
  | 'formula'
  | 'created_at'
  | 'updated_at'
  | 'created_by'
  | 'updated_by'
export type BaseField = {
  id: string
  name: string
  type: FieldType
  config: Record<string, unknown>
  version: number
  is_primary: boolean
  position?: string
}
export type ViewType = 'grid' | 'kanban' | 'gallery'
export type BaseView = {
  id: string
  name: string
  type: ViewType
  config: Record<string, unknown>
  version: number
  position?: string
}
export type BaseTable = { id: string; page_id: string; name: string; data_version: number; record_count: number }
export type TableSchema = {
  table: BaseTable
  fields: BaseField[]
  views: BaseView[]
  mode: 'local' | 'remote'
  timezone?: string
  limits?: { group_count: number }
  local_query?: { text_contains_ascii: boolean; jsonb_compare: boolean }
}
export type Condition = {
  field_id: string
  operator: 'is' | 'contains' | 'is_empty' | 'is_not_empty' | 'gt' | 'gte' | 'lt' | 'lte' | 'text_contains'
  value?: Value
}
export type Filter = { conjunction: 'and' | 'or'; conditions: Condition[] }
export type Sort = { field_id: string; direction: 'asc' | 'desc' }
export type RecordQuery = {
  filter?: Filter
  sort?: Sort[]
  page_size?: number
  page_token?: string
  ids?: string[]
  local?: boolean
  group?: { field_id: string; value?: Value; value_json?: string | null }
}
export type RecordsResult = {
  records: BaseRecord[]
  data_version: number
  page_token?: string | null
  complete: boolean
}
export type GroupBy = { field_id: string; bucket?: 'day' | 'week' | 'month' | 'quarter' | 'year' }
export type Metric = { operation: 'count' | 'sum' | 'avg' | 'min' | 'max'; field_id?: string; alias: string }
export type AggregateQuery = { filter?: Filter; group_by?: GroupBy[]; metrics: Metric[] }
export type AggregateResult = {
  groups: { values: Value[]; value_json?: (string | null)[]; metrics: Record<string, Value> }[]
  data_version: number
}
export type RecordWrite = {
  creates?: { id?: string; data: RecordData }[]
  updates?: { id: string; data: RecordData; expected_versions: Versions }[]
  deletes?: { id: string; expected_versions: Versions }[]
}
export type WriteResult = { records: BaseRecord[]; deleted_ids: string[]; data_version: number }
export type TableEvent = {
  resync?: boolean
  data_version?: number
  changed_ids?: string[]
  deleted_ids?: string[]
  schema_changed?: boolean
  access_revoked?: boolean
}
export type PresenceMember = { id: string; [key: string]: unknown }
export type EphemeralChannel = {
  broadcast(event: string, payload: unknown): Promise<void>
  on(event: string, callback: (payload: unknown) => void): () => void
  presence(): PresenceMember[]
  subscribe(callback: () => void): () => void
  close(): void
}
export type PodAPI = { request<T>(path: string, method?: string, body?: unknown): Promise<T> }
export type BaseAPI = {
  schema(tableID: string): Promise<TableSchema>
  records(tableID: string, query: RecordQuery): Promise<RecordsResult>
  aggregate(tableID: string, query: AggregateQuery): Promise<AggregateResult>
  /** The host refreshes the table cache after writes and live events. */
  write(tableID: string, changes: RecordWrite): Promise<WriteResult>
  subscribe(tableID: string, callback: (event: TableEvent) => void): () => void
  key(tableID: string): readonly unknown[]
}
export type RouteMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'
export type GetRoute = `GET /${string}`
export type MutationRoute = `${Exclude<RouteMethod, 'GET'>} /${string}`
export type Route = GetRoute | MutationRoute
export type RouteParams = Record<string, string>
export type RouteQuery = Record<string, string | string[]>
export type RouteRequest = { query?: RouteQuery; body?: unknown; signal?: AbortSignal }
export type RouteCall = RouteRequest & { method: RouteMethod; path: string }
export type RouteVariables = { params?: RouteParams; query?: RouteQuery; body?: unknown }
export type RoutesAPI = {
  call<T = unknown>(request: RouteCall): Promise<T>
  key(): readonly unknown[]
}
export type AppletRuntime = {
  pageID: string
  instanceID: string
  actions: readonly ('node_view' | 'node_comment' | 'node_contribute' | 'node_edit' | 'node_manage')[]
  revision: number
  routes: RoutesAPI
  queryClient: QueryClient
  readDenial(query: Query): unknown
  base: BaseAPI
  pod: PodAPI
  channel(name: string): EphemeralChannel
  principal?: { uid: string; name?: string }
  theme?: string
}
