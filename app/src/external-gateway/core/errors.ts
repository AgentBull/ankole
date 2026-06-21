/**
 * Base error for the External Gateway layer.
 *
 * Carries a stable machine-readable `code` so callers can branch on the kind of
 * failure without matching on the human-readable message, which is free to
 * change. The original `cause` is kept for logging and debugging.
 */
export class ExternalGatewayError extends Error {
  readonly code: string
  override readonly cause?: unknown

  constructor(message: string, code: string, cause?: unknown) {
    super(message)
    this.name = 'ExternalGatewayError'
    this.code = code
    this.cause = cause
  }
}

/**
 * Raised when an outbound operation needs a capability the bound adapter does
 * not declare (or did not implement the matching method for).
 *
 * The outbox treats this as a permanent, non-retryable outcome: a missing
 * capability will not appear on a later attempt, so the row is marked
 * `unsupported` rather than retried.
 */
export class UnsupportedChannelCapabilityError extends ExternalGatewayError {
  readonly adapterName: string
  readonly capability: string

  constructor(adapterName: string, capability: string, cause?: unknown) {
    super(
      `Adapter "${adapterName}" does not support channel capability "${capability}"`,
      'UNSUPPORTED_CHANNEL_CAPABILITY',
      cause
    )
    this.name = 'UnsupportedChannelCapabilityError'
    this.adapterName = adapterName
    this.capability = capability
  }
}
