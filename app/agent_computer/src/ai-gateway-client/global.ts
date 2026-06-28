import type { LogWarningsFunction } from './logger/log-warnings'
import type { Telemetry } from './telemetry/telemetry'

declare global {
  /**
   * The warning logger to use for the AI SDK.
   *
   * If not set, the default logger is the console.warn function.
   *
   * If set to false, no warnings are logged.
   */
  var AI_SDK_LOG_WARNINGS: LogWarningsFunction | undefined | false

  /**
   * Globally registered telemetry integrations for the AI SDK.
   *
   * Integrations registered here receive lifecycle events (onStart, onStepStart,
   * etc.) from every `generateText`, `streamText`, and similar call.
   *
   * Prefer using `registerTelemetry()` from `'ai'` instead of
   * assigning this directly.
   */
  var AI_SDK_TELEMETRY_INTEGRATIONS: Telemetry[] | undefined
}
