// @ts-nocheck
import type { TranscriptionModelV2, TranscriptionModelV3, TranscriptionModelV4 } from '@/llm/provider'

/**
 * Transcription model that is used by the AI SDK.
 */
export type TranscriptionModel = string | TranscriptionModelV4 | TranscriptionModelV3 | TranscriptionModelV2
