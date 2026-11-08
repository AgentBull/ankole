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
  description: string
  type: FieldType
  config: Record<string, unknown>
  version: number
  is_primary: boolean
  position?: string
}
export type SelectOption = { id?: string; name: string; color?: string }
export type ViewType = 'grid' | 'kanban' | 'gallery' | 'chart'
export type BaseView = {
  id: string
  name: string
  type: ViewType
  config: Record<string, unknown>
  version: number
  position?: string
}
export type BaseTable = {
  id: string
  page_id: string
  name: string
  description: string
  data_version: number
  record_count: number
  unique_field_ids: string[]
  emit_changes: boolean
}
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
export type TimeBucket = 'day' | 'week' | 'month' | 'quarter' | 'year'
export type GroupSlice = {
  field_id: string
  value?: Value
  value_json?: string | null
  bucket?: TimeBucket
  cumulative_from_json?: string | null
  other_exclude_values_json?: string[]
}
export type RecordQuery = {
  filter?: Filter
  sort?: Sort[]
  page_size?: number
  page_token?: string
  ids?: string[]
  local?: boolean
  group?: GroupSlice | GroupSlice[]
  groups?: GroupSlice[]
}
export type RecordsResult = {
  records: BaseRecord[]
  data_version: number
  page_token?: string | null
  complete: boolean
}
/** Link field IDs followed from the queried table; `field_id` then names a field of the reached table. */
export type LinkPath = string[]
export type AggregateCondition =
  | (Condition & { path?: LinkPath })
  | { operator: 'exists' | 'not_exists'; path: LinkPath; filter?: Filter }
export type AggregateFilter = { conjunction: 'and' | 'or'; conditions: AggregateCondition[] }
export type GroupBy = { field_id: string; bucket?: TimeBucket; path?: LinkPath }
export type MetricOperation = 'count' | 'sum' | 'avg' | 'min' | 'max' | 'count_distinct'
export type Metric = { operation: MetricOperation; field_id?: string; alias: string; path?: LinkPath; filter?: Filter }
export type AggregateOrderBy = { metric_alias?: string; group_index?: number; direction: 'asc' | 'desc' }
export type AggregateTopN = { limit: number; include_other?: boolean; target_group_index?: number }
export type AggregateQuery = {
  filter?: AggregateFilter
  group_by?: GroupBy[]
  metrics: Metric[]
  order_by?: AggregateOrderBy[]
  top_n?: AggregateTopN
  omit_empty?: boolean
}
export type AggregateGroup = {
  values: Value[]
  value_json?: (string | null)[]
  other?: boolean[]
  metrics: Record<string, Value>
  metrics_text?: Record<string, string | null>
}
export type AggregateResult = {
  groups: AggregateGroup[]
  data_version: number
  /** Server results key the data version of every table the query read by table ID. */
  data_versions?: Record<string, number>
}
export type MetricQueryOptions = {
  /** A pinned immutable revision; omit it for the latest published revision. */
  revision?: number
  /** The metric's typed parameters, plus `dimensions` from its addible dimensions. */
  params?: Record<string, unknown> & { dimensions?: string[] }
}
export type MetricResult = {
  metric: { id: string; slug: string; title: string }
  revision: {
    id: string
    revision: number
    latest: boolean
    status: 'published'
    approved_by: string
    created_at: string
  }
  definition: {
    grain: string
    unit: string
    numerator: string
    denominator: string | null
    time_field: string | null
    addible_dimensions: Record<string, string>[]
  }
  source: Record<string, unknown> & { kind: 'base' | 'connector' }
  params: Record<string, unknown>
  dimensions: string[]
  executed_spec: Record<string, unknown>
  /** Base aggregate groups, or the connector query's evidence envelope. */
  result: AggregateResult | Record<string, unknown>
  /** The data version of every Base table the metric read, by table ID. */
  data_versions: Record<string, number>
  executed_at: string
}
export type RecordWrite = {
  creates?: { id?: string; data: RecordData }[]
  upserts?: { data: RecordData }[]
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
export type ActionRun = {
  id: number
  automation_job_id: number
  event: Record<string, unknown>
  status: 'queued' | 'running' | 'succeeded' | 'failed' | 'cancelled'
  slice_count: number
  attempts: number
  progress: Record<string, unknown>
  result?: unknown
  error?: string | null
  started_at?: string | null
  finished_at?: string | null
  stdout?: string | null
  stdout_truncated: boolean
  stderr?: string | null
  stderr_truncated: boolean
}
export type RunsAPI = {
  get(runID: number, signal?: AbortSignal): Promise<ActionRun>
  key(runID: number): readonly unknown[]
  subscribe(runID: number, callback: (event: { access_revoked?: boolean }) => void): () => void
}
export type AppletTheme = 'light' | 'dark'
export type AppletRuntime = {
  pageID: string
  /** The Applet Page's current title; renaming the Page renders the Applet again with the new title. */
  title: string
  /** True when a document embeds the Applet; the document already shows the Page title above it. */
  embedded: boolean
  instanceID: string
  actions: readonly ('node_view' | 'node_comment' | 'node_contribute' | 'node_edit' | 'node_manage')[]
  revision: number
  routes: RoutesAPI
  runs: RunsAPI
  queryClient: QueryClient
  readDenial(query: Query): unknown
  base: BaseAPI
  pod: PodAPI
  channel(name: string): EphemeralChannel
  principal?: { uid: string; name?: string }
  theme: AppletTheme
}
