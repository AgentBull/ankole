/**
 * The Console uses one shape for the v1 and the v2 API: a flat record and the
 * `{ error: { code, message, details } }` failure. The v2 API sends JSON:API
 * documents. This module changes them to the Console shape at one point, so a
 * page that moves to a v2 SDK function keeps its logic.
 */

export const JSON_API_MEDIA_TYPE = 'application/vnd.api+json'

interface ResourceObject {
  id: string
  type?: string
  attributes?: object
}

/** The flat Console record of a JSON:API resource object type. */
export type Flat<R> = R extends { id: infer Id; attributes?: infer Attributes }
  ? { id: Id } & NonNullable<Attributes>
  : never

/** Changes a resource object to `{ id, ...attributes }`. */
function fromResource<R extends ResourceObject>(resource: R): Flat<R> {
  return { ...resource.attributes, id: resource.id } as Flat<R>
}

/**
 * Changes a JSON:API document to its flat record, or to a list of flat records.
 * The generated document types have an optional `data`; a successful response
 * always has it.
 *
 * AshJsonApi 1.7.1 gives no OpenAPI type to a `utc_datetime_usec`, a Principal
 * UID, a JSON object, or a nullable attribute, so the generated type of such a
 * field is `unknown`. A page casts the flat record to the record type that it
 * reads, for example `fromDocument(document) as AutomationJobItem[]`.
 */
export function fromDocument<R extends ResourceObject>(document: { data?: R[] }): Flat<R>[]
export function fromDocument<R extends ResourceObject>(document: { data?: R }): Flat<R>
export function fromDocument<R extends ResourceObject>(document: { data?: R | R[] }): Flat<R> | Flat<R>[] {
  return Array.isArray(document.data) ? document.data.map(fromResource) : fromResource(document.data as R)
}

interface JSONAPIError {
  code?: string
  title?: string
  detail?: string
  source?: { pointer?: string; parameter?: string }
  meta?: Record<string, unknown>
}

interface ConsoleFailure {
  error: { code: string; message: string; details: Record<string, unknown>[] }
}

/**
 * Changes a JSON:API error document to the Console failure shape. The first
 * error gives the code and the message. Errors at a request field give the
 * details; when all errors are at a field, the code is `validation_failed` as
 * in v1. A domain rejection gives its details in `meta.details`. An Ash error
 * message can name its `meta` values as `%{name}`. Other payloads, for example
 * the session and data context failures of the shared pipeline, stay the same.
 * The v2 clients use this function as their error interceptor.
 */
export function fromErrors(payload: unknown): unknown {
  const errors = jsonAPIErrors(payload)
  const [first] = errors
  if (!first) return payload

  const fieldErrors = errors.filter(error => error.source?.pointer || error.source?.parameter)
  const details: Record<string, unknown>[] = fieldErrors.length
    ? fieldErrors.map(error => ({ path: fieldPath(error.source!), message: message(error) ?? '' }))
    : metaDetails(first)
  const code = fieldErrors.length === errors.length ? 'validation_failed' : (first.code ?? 'request_failed')

  return {
    error: { code, message: message(first) ?? code, details }
  } satisfies ConsoleFailure
}

function message(error: JSONAPIError): string | undefined {
  const text = error.detail ?? error.title
  return text?.replace(/%\{(\w+)\}/g, (variable, name: string) => {
    const value = error.meta?.[name]
    return typeof value === 'string' || typeof value === 'number' ? String(value) : variable
  })
}

function metaDetails(error: JSONAPIError): Record<string, unknown>[] {
  const details = error.meta?.details
  return Array.isArray(details)
    ? details.filter((detail): detail is Record<string, unknown> => Boolean(detail && typeof detail === 'object'))
    : []
}

function jsonAPIErrors(payload: unknown): JSONAPIError[] {
  if (!payload || typeof payload !== 'object' || !('errors' in payload)) return []
  const errors = (payload as { errors?: unknown }).errors
  return Array.isArray(errors)
    ? errors.filter((error): error is JSONAPIError => Boolean(error && typeof error === 'object'))
    : []
}

// "/data/attributes/name" names the field "name", and so does "/data/name" (an
// argument of a generic action route); a query parameter keeps its name.
function fieldPath(source: { pointer?: string; parameter?: string }): string {
  if (source.pointer) return source.pointer.replace(/^\/data\/((attributes|relationships)\/)?/, '').replace(/^\//, '')
  return source.parameter ?? ''
}
