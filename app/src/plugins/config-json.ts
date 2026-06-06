import type { BullXPluginJsonValue } from '@agentbull/bullx-sdk/plugins'

export type PluginConfigJsonObject = { [key: string]: BullXPluginJsonValue }

export interface PluginSetupConfigShape {
  defaultConfig?: BullXPluginJsonValue
  fields?: readonly {
    defaultValue?: BullXPluginJsonValue
    path: readonly string[]
  }[]
}

export function defaultPluginConfigForSetup(setup: PluginSetupConfigShape | undefined): PluginConfigJsonObject {
  let config = isPluginConfigJsonObject(setup?.defaultConfig) ? clonePluginJsonObject(setup.defaultConfig) : {}

  for (const field of setup?.fields ?? []) {
    if (field.defaultValue !== undefined && getPluginConfigPath(config, field.path) === undefined) {
      config = setPluginConfigPath(config, field.path, clonePluginJsonValue(field.defaultValue))
    }
  }

  return config
}

export function getPluginConfigPath(
  value: PluginConfigJsonObject,
  path: readonly string[]
): BullXPluginJsonValue | undefined {
  let current: BullXPluginJsonValue | undefined = value
  for (const segment of path) {
    if (!isPluginConfigJsonObject(current)) return undefined
    current = current[segment]
  }

  return current
}

export function setPluginConfigPath(
  source: PluginConfigJsonObject,
  path: readonly string[],
  value: BullXPluginJsonValue
): PluginConfigJsonObject {
  if (path.length === 0) return clonePluginJsonObject(source)

  const target = clonePluginJsonObject(source)
  let current = target
  for (const segment of path.slice(0, -1)) {
    const existing = current[segment]
    const next = isPluginConfigJsonObject(existing) ? clonePluginJsonObject(existing) : {}
    current[segment] = next
    current = next
  }
  current[path[path.length - 1]!] = value

  return target
}

export function mergePluginConfigObjects(
  base: PluginConfigJsonObject,
  override: PluginConfigJsonObject
): PluginConfigJsonObject {
  const next = clonePluginJsonObject(base)
  for (const [key, value] of Object.entries(override)) {
    const baseValue = next[key]
    if (isPluginConfigJsonObject(baseValue) && isPluginConfigJsonObject(value)) {
      next[key] = mergePluginConfigObjects(baseValue, value)
      continue
    }

    next[key] = clonePluginJsonValue(value)
  }

  return next
}

export function clonePluginJsonObject(value: PluginConfigJsonObject): PluginConfigJsonObject {
  return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, clonePluginJsonValue(item)]))
}

export function clonePluginJsonValue<TValue extends BullXPluginJsonValue | undefined>(value: TValue): TValue {
  if (value === undefined) return value
  if (Array.isArray(value)) return value.map(item => clonePluginJsonValue(item)) as TValue
  if (isPluginConfigJsonObject(value)) return clonePluginJsonObject(value) as TValue

  return value
}

export function isPluginConfigJsonObject(value: unknown): value is PluginConfigJsonObject {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
