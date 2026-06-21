import { isPlainObject, mapValues } from '@pleisto/active-support'
import type { BullXPluginJsonValue } from '@agentbull/bullx-sdk/plugins'

export type PluginConfigJsonObject = { [key: string]: BullXPluginJsonValue }

export interface PluginSetupConfigShape {
  defaultConfig?: BullXPluginJsonValue
  fields?: readonly {
    defaultValue?: BullXPluginJsonValue
    path: readonly string[]
  }[]
}

/**
 * Builds the initial setup form value for a plugin.
 *
 * Field defaults fill only missing paths so a plugin can provide a broad
 * `defaultConfig` and override just the unset leaves from field metadata.
 */
export function defaultPluginConfigForSetup(setup: PluginSetupConfigShape | undefined): PluginConfigJsonObject {
  let config = isPluginConfigJsonObject(setup?.defaultConfig) ? clonePluginJsonObject(setup.defaultConfig) : {}

  for (const field of setup?.fields ?? []) {
    if (field.defaultValue !== undefined && getPluginConfigPath(config, field.path) === undefined) {
      config = setPluginConfigPath(config, field.path, clonePluginJsonValue(field.defaultValue))
    }
  }

  return config
}

/**
 * Reads a nested plugin config value without treating arrays or primitives as
 * path containers.
 */
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

/**
 * Returns a cloned config object with one nested path set.
 *
 * The source object is never mutated because setup screens may keep old config
 * snapshots for diffing, validation, or undo-like UI state.
 */
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

/**
 * Deep-merges plugin config objects while replacing arrays and scalar values.
 *
 * Plugin config is JSON data, not a class graph; cloning at each write boundary
 * prevents runtime plugin code from mutating setup defaults by reference.
 */
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

/** Clones a plugin JSON object while preserving JSON-compatible leaf values. */
export function clonePluginJsonObject(value: PluginConfigJsonObject): PluginConfigJsonObject {
  return mapValues(value, item => clonePluginJsonValue(item)) as PluginConfigJsonObject
}

/** Clones any supported plugin JSON value. */
export function clonePluginJsonValue<TValue extends BullXPluginJsonValue | undefined>(value: TValue): TValue {
  if (value === undefined) return value
  if (Array.isArray(value)) return value.map(item => clonePluginJsonValue(item)) as TValue
  if (isPluginConfigJsonObject(value)) return clonePluginJsonObject(value) as TValue

  return value
}

/** Narrows unknown JSON to the object shape accepted for plugin config roots. */
export function isPluginConfigJsonObject(value: unknown): value is PluginConfigJsonObject {
  return isPlainObject(value)
}
