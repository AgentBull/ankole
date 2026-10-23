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

type Flat<R> = R extends { id: infer Id; attributes?: infer Attributes } ? { id: Id } & NonNullable<Attributes> : never

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
}

interface ConsoleFailure {
  error: { code: string; message: string; details: { path: string; message: string }[] }
}

/**
 * Changes a JSON:API error document to the Console failure shape. The first
 * error gives the code and the message. Errors at a request field give the
 * details; when all errors are at a field, the code is `validation_failed` as
 * in v1. Other payloads, for example the session and data context failures of
 * the shared pipeline, stay the same. The v2 clients use this function as their
 * error interceptor.
 */
export function fromErrors(payload: unknown): unknown {
  const errors = jsonAPIErrors(payload)
  const [first] = errors
  if (!first) return payload

  const details = errors
    .filter(error => error.source?.pointer || error.source?.parameter)
    .map(error => ({ path: fieldPath(error.source!), message: error.detail ?? error.title ?? '' }))
  const code = details.length === errors.length ? 'validation_failed' : (first.code ?? 'request_failed')

  return {
    error: { code, message: first.detail ?? first.title ?? code, details }
  } satisfies ConsoleFailure
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

/**
 * Gives the keyset after the last record of a page, or `undefined` on the last
 * page. AshJsonApi puts it in the `page[after]` parameter of `links.next`; the
 * generated document types do not declare `links`.
 */
export function nextPageAfter(document: object | undefined): string | undefined {
  const next = (document as { links?: { next?: string | null } } | undefined)?.links?.next
  return next ? (new URL(next, 'http://localhost').searchParams.get('page[after]') ?? undefined) : undefined
}
