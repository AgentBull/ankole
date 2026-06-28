import type { TranscriptionModelCallOptions } from './transcription-model-call-options'
import type { TranscriptionModelResult } from './transcription-model-result'

/**
 * Transcription model specification version 3.
 */
export type TranscriptionModel = {
  /**
   * The transcription model must specify which transcription model interface
   * version it implements. This will allow us to evolve the transcription
   * model interface and retain backwards compatibility. The different
   * implementation versions can be handled as a discriminated union
   * on our side.
   */
  /**
   * Name of the provider for logging purposes.
   */
  readonly provider: string

  /**
   * Provider-specific model ID for logging purposes.
   */
  readonly modelId: string

  /**
   * Generates a transcript.
   */
  doGenerate(options: TranscriptionModelCallOptions): PromiseLike<TranscriptionModelResult>
}
