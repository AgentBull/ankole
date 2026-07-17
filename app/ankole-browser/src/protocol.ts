import { z } from 'zod'
import { BrowserDataError } from './errors'

export const BrowserProtocolVersion = 1 as const

export const BrowserErrorCodeSchema = z.enum([
  'invalid_command',
  'invalid_result',
  'missing_route',
  'invalid_material',
  'session_spec_conflict',
  'session_busy',
  'no_page',
  'stale_ref',
  'dialog_blocked',
  'timeout',
  'cancelled',
  'backend_unavailable',
  'session_lost',
  'internal'
])

export type BrowserErrorCode = z.infer<typeof BrowserErrorCodeSchema>

const HeaderMapSchema = z.record(z.string(), z.string())
const JSONRecordSchema = z.record(z.string(), z.unknown())

export const LocalChromiumBackendSchema = z
  .object({
    kind: z.literal('local_chromium'),
    executable: z.string().min(1),
    args: z.array(z.string()).default([])
  })
  .strict()

export const RemoteCDPBackendSchema = z
  .object({
    kind: z.literal('remote_cdp'),
    endpoint: z.string().url(),
    headers: HeaderMapSchema.default({}),
    connect_timeout_ms: z.number().int().positive().max(120_000).default(30_000),
    session_identity: z.string().min(1)
  })
  .strict()

const RemoteSessionHTTPRequestSchema = z
  .object({
    url: z.string().url(),
    method: z.enum(['POST', 'PUT']),
    headers: HeaderMapSchema.default({}),
    body: z.unknown().optional()
  })
  .strict()

const RemoteSessionResponseSchema = z
  .object({
    endpoint_json_path: z.array(z.string().min(1)).min(1)
  })
  .strict()

export const RemoteSessionRequestBackendSchema = z
  .object({
    kind: z.literal('remote_session_request'),
    request: RemoteSessionHTTPRequestSchema,
    response: RemoteSessionResponseSchema,
    connect_headers: HeaderMapSchema.default({}),
    connect_timeout_ms: z.number().int().positive().max(120_000).default(30_000),
    session_identity: z.string().min(1),
    cleanup_request: RemoteSessionHTTPRequestSchema.optional()
  })
  .strict()

export const BrowserBackendSchema = z.discriminatedUnion('kind', [
  LocalChromiumBackendSchema,
  RemoteCDPBackendSchema,
  RemoteSessionRequestBackendSchema
])

export type BrowserBackend = z.infer<typeof BrowserBackendSchema>

export const BrowserProfileSchema = z
  .object({
    mode: z.literal('persistent_user_data_dir'),
    seed_path: z.string().min(1).optional(),
    seed_fingerprint: z.string().min(1).optional()
  })
  .strict()

export const BrowserMaterialSchema = z
  .object({
    protocol_version: z.literal(BrowserProtocolVersion),
    route_id: z.string().regex(/^br_[A-Za-z0-9_-]{16,128}$/),
    data_root: z.string().min(1),
    artifact_root: z.string().min(1),
    immutable_fingerprint: z.string().min(1),
    material_generation: z.number().int().nonnegative(),
    profile: BrowserProfileSchema,
    backend: BrowserBackendSchema,
    navigation: z
      .object({
        ssrf_filter: z.boolean().default(true),
        allow_file_urls: z.boolean().default(false)
      })
      .strict()
      .default({ ssrf_filter: true, allow_file_urls: false }),
    idle_ttl_ms: z
      .number()
      .int()
      .positive()
      .max(7 * 24 * 60 * 60 * 1000)
      .default(30 * 60 * 1000)
  })
  .strict()

export type BrowserMaterial = z.infer<typeof BrowserMaterialSchema>

const NonEmptyString = z.string().min(1, 'must be a non-empty string')
const PositiveInt = z.number().int('must be a positive integer').positive('must be a positive integer')
const NonNegativeInt = z.number().int('must be a non-negative integer').nonnegative('must be a non-negative integer')

export const ScrollDirectionSchema = z.enum(['up', 'down', 'left', 'right'])
export const GetPropertySchema = z.enum(['text', 'html', 'value', 'attr', 'title', 'url', 'count', 'box'])
export const IsPredicateSchema = z.enum(['visible', 'enabled', 'checked'])
export const FindKindSchema = z.enum(['role', 'text', 'label', 'placeholder', 'testid', 'first', 'last', 'nth'])
export const FindActionSchema = z.enum(['click', 'fill', 'type', 'hover', 'focus', 'check', 'uncheck', 'text'])
export const TabActionSchema = z.enum(['list', 'new', 'switch', 'close'])
export const DialogActionSchema = z.enum(['status', 'accept', 'dismiss'])
export const WaitLoadStateSchema = z.enum(['load', 'domcontentloaded', 'networkidle'])
export const LifecycleVerbSchema = z.enum(['reset', 'purge'])

const SelectorArgsSchema = z.object({ selector: NonEmptyString }).strict()
const TypeTextArgsSchema = z.object({ selector: NonEmptyString, text: NonEmptyString }).strict()

const OpenArgsSchema = z.object({ url: NonEmptyString.optional() }).strict()

const SnapshotArgsSchema = z
  .object({
    interactive: z.boolean().optional(),
    compact: z.boolean().optional(),
    urls: z.boolean().optional(),
    depth: PositiveInt.optional(),
    selector: NonEmptyString.optional()
  })
  .strict()

const ScreenshotArgsSchema = z
  .object({
    path: NonEmptyString.optional(),
    full: z.boolean().optional(),
    annotate: z.boolean().optional()
  })
  .strict()

const PressArgsSchema = z.object({ key: NonEmptyString }).strict()
const SelectArgsSchema = z.object({ selector: NonEmptyString, value: NonEmptyString }).strict()

const ScrollArgsSchema = z
  .object({
    direction: ScrollDirectionSchema,
    pixels: PositiveInt.optional(),
    selector: NonEmptyString.optional()
  })
  .strict()

const DragArgsSchema = z.object({ source: NonEmptyString, target: NonEmptyString }).strict()

const UploadArgsSchema = z
  .object({
    selector: NonEmptyString,
    paths: z.array(NonEmptyString).min(1, 'requires at least one file path')
  })
  .strict()

const GetArgsSchema = z.discriminatedUnion('property', [
  z.object({ property: z.literal('title') }).strict(),
  z.object({ property: z.literal('url') }).strict(),
  z.object({ property: z.literal('attr'), selector: NonEmptyString, attribute: NonEmptyString }).strict(),
  z.object({ property: z.literal(['text', 'html', 'value', 'count', 'box']), selector: NonEmptyString }).strict()
])

const IsArgsSchema = z.object({ predicate: IsPredicateSchema, selector: NonEmptyString }).strict()

const FindArgsSchema = z
  .discriminatedUnion('kind', [
    z
      .object({
        kind: z.literal('nth'),
        index: NonNegativeInt,
        selector: NonEmptyString,
        action: FindActionSchema.optional(),
        text: NonEmptyString.optional()
      })
      .strict(),
    z
      .object({
        kind: z.literal(['role', 'text', 'label', 'placeholder', 'testid', 'first', 'last']),
        value: NonEmptyString,
        name: NonEmptyString.optional(),
        exact: z.boolean().optional(),
        action: FindActionSchema.optional(),
        text: NonEmptyString.optional()
      })
      .strict()
  ])
  .superRefine((args, context) => {
    if ((args.action === 'fill' || args.action === 'type') && args.text === undefined) {
      context.addIssue({ code: 'custom', path: ['text'], message: 'must be a non-empty string' })
    }
  })

const WaitArgsSchema = z
  .object({
    ms: PositiveInt.optional(),
    selector: NonEmptyString.optional(),
    text: NonEmptyString.optional(),
    url: NonEmptyString.optional(),
    load: WaitLoadStateSchema.optional(),
    expression: NonEmptyString.optional()
  })
  .strict()
  .superRefine((args, context) => {
    if (Object.values(args).every(value => value === undefined)) {
      context.addIssue({ code: 'custom', message: 'wait requires a condition' })
    }
  })

const TabArgsSchema = z.discriminatedUnion('action', [
  z.object({ action: z.literal('list') }).strict(),
  z.object({ action: z.literal('new'), url: NonEmptyString.optional() }).strict(),
  z.object({ action: z.literal(['switch', 'close']), index: NonNegativeInt }).strict()
])

const FrameArgsSchema = z.object({ target: NonEmptyString }).strict()

const DialogArgsSchema = z.discriminatedUnion('action', [
  z.object({ action: z.literal('status') }).strict(),
  z.object({ action: z.literal('dismiss') }).strict(),
  z.object({ action: z.literal('accept'), text: z.string().optional() }).strict()
])

const EvalArgsSchema = z.object({ expression: NonEmptyString }).strict()

const FetchArgsSchema = z
  .object({
    urls: z.array(NonEmptyString).min(1, 'requires at least one URL').max(5, 'accepts at most five URLs')
  })
  .strict()

const EmptyArgsSchema = z.object({}).strict()
const LifecycleArgsSchema = z.object({ verb: LifecycleVerbSchema }).strict()
const LeaseAcquireArgsSchema = z.object({ run_id: NonEmptyString }).strict()
const LeaseDelegateArgsSchema = z.object({ lease_token: NonEmptyString }).strict()
const LeaseReleaseArgsSchema = z.object({ lease_token: NonEmptyString, outcome: NonEmptyString.optional() }).strict()

function browserCommandArm<Name extends string, Args extends z.ZodType>(name: Name, args: Args) {
  return z.object({ name: z.literal(name), args }).strict()
}

const PageCommandArms = [
  browserCommandArm('open', OpenArgsSchema),
  browserCommandArm('snapshot', SnapshotArgsSchema),
  browserCommandArm('screenshot', ScreenshotArgsSchema),
  browserCommandArm('click', SelectorArgsSchema),
  browserCommandArm('dblclick', SelectorArgsSchema),
  browserCommandArm('focus', SelectorArgsSchema),
  browserCommandArm('hover', SelectorArgsSchema),
  browserCommandArm('scrollintoview', SelectorArgsSchema),
  browserCommandArm('check', SelectorArgsSchema),
  browserCommandArm('uncheck', SelectorArgsSchema),
  browserCommandArm('fill', TypeTextArgsSchema),
  browserCommandArm('type', TypeTextArgsSchema),
  browserCommandArm('press', PressArgsSchema),
  browserCommandArm('select', SelectArgsSchema),
  browserCommandArm('scroll', ScrollArgsSchema),
  browserCommandArm('drag', DragArgsSchema),
  browserCommandArm('upload', UploadArgsSchema),
  browserCommandArm('get', GetArgsSchema),
  browserCommandArm('is', IsArgsSchema),
  browserCommandArm('find', FindArgsSchema),
  browserCommandArm('wait', WaitArgsSchema),
  browserCommandArm('tab', TabArgsSchema),
  browserCommandArm('frame', FrameArgsSchema),
  browserCommandArm('dialog', DialogArgsSchema),
  browserCommandArm('eval', EvalArgsSchema),
  browserCommandArm('fetch', FetchArgsSchema)
] as const

const StatusCommandArm = browserCommandArm('status', EmptyArgsSchema)

export const BrowserPageCommandSchema = z.discriminatedUnion('name', [...PageCommandArms])

export const BrowserBatchItemSchema = z.discriminatedUnion('name', [StatusCommandArm, ...PageCommandArms])

const BatchArgsSchema = z
  .object({
    commands: z.array(BrowserBatchItemSchema),
    bail: z.boolean().optional()
  })
  .strict()

export const BrowserCommandSchema = z.discriminatedUnion('name', [
  StatusCommandArm,
  ...PageCommandArms,
  browserCommandArm('close', EmptyArgsSchema),
  browserCommandArm('batch', BatchArgsSchema),
  browserCommandArm('lifecycle', LifecycleArgsSchema),
  browserCommandArm('lease.acquire', LeaseAcquireArgsSchema),
  browserCommandArm('lease.delegate', LeaseDelegateArgsSchema),
  browserCommandArm('lease.release', LeaseReleaseArgsSchema)
])

export type BrowserPageCommand = z.infer<typeof BrowserPageCommandSchema>
export type BrowserBatchItem = z.infer<typeof BrowserBatchItemSchema>
export type BrowserCommand = z.infer<typeof BrowserCommandSchema>
export type BrowserCommandArgs<Name extends BrowserCommand['name']> = Extract<BrowserCommand, { name: Name }>['args']

export const BrowserRequestSchema = z
  .object({
    v: z.literal(BrowserProtocolVersion),
    id: z.string().min(1),
    route: z.string().min(1),
    session: z.string().regex(/^[A-Za-z0-9._-]{1,64}$/),
    material: BrowserMaterialSchema,
    deadline_unix_ms: z.number().int().positive(),
    command: BrowserCommandSchema
  })
  .strict()

export type BrowserRequest = z.infer<typeof BrowserRequestSchema>

export function parseBrowserRequest(raw: unknown): BrowserRequest {
  const parsed = BrowserRequestSchema.safeParse(raw)
  if (parsed.success) return parsed.data
  const issues = parsed.error.issues.map(issue => describeRequestIssue(issue, raw))
  throw new BrowserDataError('invalid_command', issues[0] ?? 'browser request schema is invalid', {
    details: { issues }
  })
}

function describeRequestIssue(issue: z.core.$ZodIssue, raw: unknown): string {
  if (issue.code === 'invalid_union' && issue.path.at(-1) === 'name') {
    const name = valueAtPath(raw, issue.path)
    if (typeof name === 'string') {
      return issue.path.includes('commands') ? `batch cannot contain ${name}` : `unsupported browser command: ${name}`
    }
  }
  const message =
    issue.code === 'invalid_type' && issue.expected === 'string'
      ? 'must be a non-empty string'
      : issue.code === 'invalid_type' && (issue.expected === 'number' || issue.expected === 'boolean')
        ? `must be a ${issue.expected}`
        : issue.message
  const path = issuePathText(issue.path)
  return path ? `${path} ${message}` : message
}

function issuePathText(path: ReadonlyArray<PropertyKey>): string {
  const local = path[0] === 'command' && path[1] === 'args' ? path.slice(2) : path
  let text = ''
  for (const segment of local) {
    if (typeof segment === 'number') text += `[${segment}]`
    else text += text ? `.${String(segment)}` : String(segment)
  }
  return text
}

function valueAtPath(raw: unknown, path: ReadonlyArray<PropertyKey>): unknown {
  let current = raw
  for (const segment of path) {
    if (current === null || typeof current !== 'object') return undefined
    current = (current as Record<PropertyKey, unknown>)[segment]
  }
  return current
}

export const BrowserErrorSchema = z
  .object({
    code: BrowserErrorCodeSchema,
    message: z.string(),
    retryable: z.boolean().default(false),
    details: JSONRecordSchema.default({})
  })
  .strict()

export type BrowserError = z.infer<typeof BrowserErrorSchema>

export const BrowserSuccessResponseSchema = z
  .object({
    v: z.literal(BrowserProtocolVersion),
    id: z.string(),
    ok: z.literal(true),
    route: z.string(),
    session: z.string(),
    data: z.unknown().optional(),
    warnings: z.array(z.string()).default([])
  })
  .strict()

export const BrowserFailureResponseSchema = z
  .object({
    v: z.literal(BrowserProtocolVersion),
    id: z.string(),
    ok: z.literal(false),
    route: z.string().optional(),
    session: z.string().optional(),
    error: BrowserErrorSchema
  })
  .strict()

export const BrowserResponseSchema = z.discriminatedUnion('ok', [
  BrowserSuccessResponseSchema,
  BrowserFailureResponseSchema
])

export type BrowserResponse = z.infer<typeof BrowserResponseSchema>
export type BrowserSuccessResponse = z.infer<typeof BrowserSuccessResponseSchema>
export type BrowserFailureResponse = z.infer<typeof BrowserFailureResponseSchema>

export function successResponse(
  request: Pick<BrowserRequest, 'id' | 'route' | 'session'>,
  data?: unknown,
  warnings: string[] = []
): BrowserSuccessResponse {
  return {
    v: BrowserProtocolVersion,
    id: request.id,
    ok: true,
    route: request.route,
    session: request.session,
    ...(data === undefined ? {} : { data }),
    warnings
  }
}

export function failureResponse(
  request: Partial<Pick<BrowserRequest, 'id' | 'route' | 'session'>>,
  error: BrowserError
): BrowserFailureResponse {
  return {
    v: BrowserProtocolVersion,
    id: request.id ?? 'unknown',
    ok: false,
    ...(request.route ? { route: request.route } : {}),
    ...(request.session ? { session: request.session } : {}),
    error
  }
}
