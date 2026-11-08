import i18n from '../common/i18n'
import { InternalAPIError } from '../common/internal-api-client'
import { requestErrorCode } from '../common/request-errors'
import { RealtimeRequestError } from './realtime'

/** Translate protocol codes at the Pod UI boundary; preserve the original error for recovery logic. */
export function contentError(error: unknown): unknown {
  const code =
    error instanceof InternalAPIError
      ? requestErrorCode(error.payload)
      : error instanceof RealtimeRequestError &&
          error.payload &&
          typeof error.payload === 'object' &&
          'reason' in error.payload
        ? String(error.payload.reason)
        : undefined
  const known = code ? `pod.errors.${code}` : ''
  // A 401 can carry its own meaning, such as a wrong verification code, so a translated code comes first.
  const key =
    known && i18n.exists(known)
      ? known
      : error instanceof InternalAPIError && error.status === 401
        ? 'pod.errors.unauthenticated'
        : code?.startsWith('invalid_')
          ? 'pod.errors.validation_failed'
          : known
  return key && i18n.exists(key) ? new Error(i18n.t(key)) : error
}
