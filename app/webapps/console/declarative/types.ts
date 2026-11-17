export type DeclarativeIconName =
  | 'board'
  | 'server'
  | 'folder'
  | 'branches'
  | 'routing'
  | 'globe'
  | 'people'
  | 'doc'
  | 'alert'
  | 'history'
  | 'key'
  | 'scales'
  | 'settings'
  | 'code'

export type DeclarativeSurfaceKind = 'resource' | 'panel' | 'action' | 'wizard' | 'dashboard'
export type DeclarativeActor = 'operator' | 'principal' | 'tenant'
export type DeclarativeOperationKind = 'list' | 'view' | 'create' | 'update' | 'delete' | 'action'
export type DeclarativeEnvelope = 'jsonapi' | 'data' | 'flat'

export type DeclarativeFieldType =
  | 'string'
  | 'integer'
  | 'number'
  | 'boolean'
  | 'string_array'
  | 'enum'
  | 'datetime'
  | 'secret'
  | 'json'
  | 'object'
  | 'key_value'
  | 'rule_tree'

export interface DeclarativeFieldDescriptor {
  readonly name: string
  readonly type: DeclarativeFieldType
  readonly labelKey: string
  readonly required: boolean
  readonly readOnly: boolean
  readonly enumValues?: readonly string[]
  readonly defaultValue?: unknown
  readonly descriptionKey?: string
  readonly placeholderKey?: string
  readonly min?: number
  readonly max?: number
  readonly fields?: readonly DeclarativeFieldDescriptor[]
  readonly keyLabelKey?: string
  readonly valueLabelKey?: string
  readonly valueType?: 'string' | 'number'
  readonly inputUnit?: 'date' | 'datetime'
  readonly multiline?: boolean
  readonly expiryPresets?: readonly number[]
}

export interface DeclarativeFilterSchema {
  readonly name: string
  readonly type: 'search' | 'select' | 'text' | 'date' | 'timezone'
  readonly labelKey: string
  readonly enumValues?: readonly string[]
  readonly placeholderKey?: string
}

export interface DeclarativeRuleTreeConfig {
  readonly operatorField: string
  readonly leafOperator: string
  readonly leafValueField: string
  readonly unaryOperators: readonly string[]
  readonly unaryChildField: string
  readonly branchOperators: readonly string[]
  readonly branchChildrenField: string
}

export interface DeclarativeRuleSection {
  readonly id: string
  readonly labelKey?: string
  readonly path: readonly string[]
  readonly kind: 'tree' | 'fields'
  readonly fields: readonly DeclarativeFieldDescriptor[]
  readonly treeConfig?: DeclarativeRuleTreeConfig
}

export interface DeclarativeOAuthPkceConfig {
  readonly authorizeEndpoint: string
  readonly clientId: string
  readonly scope: string
  readonly verifierField: string
  readonly callbackField: string
  readonly redirectUriField: string
  readonly attrsField?: string
}

export interface DeclarativeBatchLinesConfig {
  readonly listField: string
  readonly textField: string
  readonly urlField: string
  readonly nameField: string
  readonly schemeField: string
  readonly schemes: readonly string[]
}

export interface DeclarativeActionPreviewConfig {
  readonly itemsField?: string
  readonly selection?: {
    readonly field: string
    readonly rowKeyField: string
    readonly selectableField?: string
  }
}

export interface DeclarativeStepSchema {
  readonly id: string
  readonly labelKey: string
  readonly kind?: 'form' | 'oauth_pkce' | 'batch_lines' | 'preview_items' | 'confirm'
  readonly fields: readonly DeclarativeFieldDescriptor[]
  readonly oauthConfig?: DeclarativeOAuthPkceConfig
  readonly batchLinesConfig?: DeclarativeBatchLinesConfig
  readonly actionSurfaceId?: string
  readonly actionPreview?: DeclarativeActionPreviewConfig
}

export type DeclarativeRowActionDescriptor =
  | {
      readonly kind: 'route'
      readonly actionId: string
      readonly labelKey: string
      readonly routeTemplate: string
    }
  | {
      readonly kind: 'toggle_patch'
      readonly actionId: string
      readonly field: string
      readonly inactiveValues: readonly string[]
      readonly inactiveValue: unknown
      readonly activeValue: unknown
      readonly activateLabelKey: string
      readonly deactivateLabelKey: string
    }
  | {
      readonly kind: 'modal' | 'action' | 'delete'
      readonly actionId: string
      readonly labelKey?: string
      readonly confirmKey?: string
    }

export interface DeclarativeResultSectionSchema {
  readonly field: string
  readonly titleKey: string
}

export interface DeclarativeResultTableSchema {
  readonly field: string
  readonly titleKey: string
  readonly columns: readonly string[]
}

export interface DeclarativeResultLatencySchema {
  readonly field: string
  readonly stages: readonly string[]
}

export type DeclarativeFieldFormat = 'usd_micros' | 'percent' | 'integer' | 'number'

export interface DeclarativeResultSchema {
  readonly summaryFields: readonly string[]
  readonly detailFields?: readonly string[]
  readonly sections?: readonly DeclarativeResultSectionSchema[]
  readonly latency?: DeclarativeResultLatencySchema
  readonly tables?: readonly DeclarativeResultTableSchema[]
  readonly fieldFormats?: Readonly<Record<string, DeclarativeFieldFormat>>
}

export interface DeclarativeDashboardFactsSection {
  readonly sourceKey: string
  readonly titleKey: string
  readonly columns?: readonly string[]
}

export interface DeclarativeDashboardTableSection {
  readonly sourceKey: string
  readonly titleKey: string
  readonly linkTo?: string
  readonly columns: readonly string[]
}

export interface DeclarativeDashboardDrilldownParams {
  readonly dateParam: string
  readonly timezoneParam?: string
  readonly promptKey?: string
  readonly actionLabelKey?: string
}

export interface DeclarativeDashboardSchema {
  readonly titleKey: string
  readonly descriptionKey?: string
  readonly windows: readonly string[]
  readonly granularities: readonly string[]
  readonly granularitiesByWindow?: Readonly<Record<string, readonly string[]>>
  readonly defaultWindow: string
  readonly defaultGranularity: string
  readonly staticQueryParams?: Readonly<Record<string, string>>
  readonly drilldownRoute?: string
  readonly drilldownParams?: DeclarativeDashboardDrilldownParams
  readonly seriesOptions?: readonly string[]
  readonly fieldFormats?: Readonly<Record<string, DeclarativeFieldFormat>>
  readonly factsSections?: readonly DeclarativeDashboardFactsSection[]
  readonly tableSections?: readonly DeclarativeDashboardTableSection[]
}

export interface DeclarativeMetricsQuery {
  readonly surfaceId?: string
  readonly granularity: string
  readonly scope: string
}

export interface DeclarativeSurfaceDescriptor {
  readonly id: string
  readonly surface: string
  readonly kind: DeclarativeSurfaceKind
  readonly domain: string
  readonly actor: DeclarativeActor
  readonly operationKind: DeclarativeOperationKind
  readonly subject: string
  readonly permission: string
  readonly audit: 'none' | 'required'
  readonly endpoint: string
  readonly method: 'GET' | 'POST' | 'PATCH' | 'PUT' | 'DELETE'
  readonly resourceType: string | null
  readonly payloadEnvelope: DeclarativeEnvelope
  readonly responseEnvelope?: DeclarativeEnvelope
  readonly titleKey: string
  readonly columns: readonly string[]
  readonly filters: readonly string[]
  readonly filterSchemas?: readonly DeclarativeFilterSchema[]
  readonly nullableFields: readonly string[]
  readonly fields: readonly DeclarativeFieldDescriptor[]
  readonly ruleSchema?: readonly DeclarativeRuleSection[] | null
  readonly stepSchemas: readonly DeclarativeStepSchema[]
  readonly toolbarActionIds?: readonly string[]
  readonly rowActions?: readonly (DeclarativeRowActionDescriptor | string)[]
  readonly createRoute?: string | null
  readonly editRoute?: string | null
  readonly linkedColumn?: string | null
  readonly detailSurfaceId?: string | null
  readonly resultSchema?: DeclarativeResultSchema | null
  readonly dashboardSchema?: DeclarativeDashboardSchema | null
  readonly presentation?: 'table' | 'stats' | 'form' | null
  readonly drilldownTarget?: string | null
  readonly panels?: readonly string[]
  readonly secretField?: string | null
  readonly initialFields?: Readonly<Record<string, unknown>> | null
  readonly metricsQuery?: DeclarativeMetricsQuery | null
}

export interface DeclarativeNavItemSpec {
  readonly id: string
  readonly to: string
  readonly match?: string
  readonly labelKey: string
  readonly icon: DeclarativeIconName
  readonly surfaceId: string
}

export interface DeclarativeNavSectionSpec {
  readonly id: string
  readonly labelKey: string
  readonly items: readonly DeclarativeNavItemSpec[]
}

export interface DeclarativeRouteTabSpec {
  readonly id: string
  readonly labelKey: string
  readonly surfaceId: string
}

export interface DeclarativeRouteSpec {
  readonly id: string
  readonly path: string
  readonly scope: 'site' | 'tenant'
  readonly surfaceId: string
  readonly titleKey?: string
  readonly backPath?: string
  readonly backLabelKey?: string
  readonly mode?: 'default' | 'create' | 'edit'
  readonly paramName?: string
  readonly detailSurfaceId?: string
  readonly tabs?: readonly DeclarativeRouteTabSpec[]
}

export interface DeclarativeConsoleManifest {
  readonly id: string
  readonly pluginId: string
  readonly visibilityEndpoint: string
  readonly i18nPrefix?: string
  readonly navSections: readonly DeclarativeNavSectionSpec[]
  readonly routes: readonly DeclarativeRouteSpec[]
  readonly surfaces: readonly DeclarativeSurfaceDescriptor[]
}
