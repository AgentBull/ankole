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
