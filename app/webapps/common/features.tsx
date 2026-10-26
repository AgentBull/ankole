import { InMemoryProvider, OpenFeature } from '@openfeature/web-sdk'

export function initializeFeatures(flags: Record<string, boolean>) {
  return OpenFeature.setProviderAndWait(
    new InMemoryProvider(
      Object.fromEntries(
        Object.entries(flags).map(([key, value]) => [
          key,
          { variants: { on: true, off: false }, defaultVariant: value ? 'on' : 'off', disabled: false }
        ])
      )
    )
  )
}
