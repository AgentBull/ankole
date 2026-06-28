import { logWarnings } from '../logger/log-warnings'

export function logV2CompatibilityWarning({ provider, modelId }: { provider: string; modelId: string }): void {
  logWarnings({
    warnings: [
      {
        type: 'compatibility',
        feature: 'provider contract',
        details: `Using v2 specification compatibility mode. Some features may not be available.`
      }
    ],
    provider,
    model: modelId
  })
}
