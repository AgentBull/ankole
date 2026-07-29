import { compareCodePointStrings } from './ordering'

type JSONObject = Record<string, unknown>

const DEFINITION_KEYS = ['$defs', 'definitions'] as const
const COMPOSITION_KEYS = ['anyOf', 'oneOf', 'allOf'] as const
const SCHEMA_CHILD_KEYS = ['items', ...COMPOSITION_KEYS] as const
const SUPPORTED_TYPES = new Set(['string', 'number', 'boolean', 'integer', 'object', 'array', 'null'])
const MAX_COMPACT_SCHEMA_BYTES = 5_000
const MAX_COMPACT_SCHEMA_DEPTH = 3

/**
 * Converts an MCP input schema to the Responses schema that Codex 0.146 emits.
 *
 * Invalid schemas return undefined. Codex omits the matching MCP tool when its
 * schema cannot be converted.
 */
export function codexMCPInputSchema(input: JSONObject): JSONObject | undefined {
  const schema = structuredClone(input)
  if (schema.properties === undefined || schema.properties === null) schema.properties = {}

  sanitizeSchema(schema)
  pruneUnreachableDefinitions(schema)
  compactLargeSchema(schema)

  try {
    const projected = projectSchema(schema)
    if (projected.type === 'null') return undefined
    return projected
  } catch {
    return undefined
  }
}

function sanitizeSchema(value: unknown): unknown {
  if (typeof value === 'boolean') return { type: 'string' }
  if (Array.isArray(value)) return value.map(sanitizeSchema)
  if (!isObject(value)) return value

  if (isObject(value.properties)) {
    for (const [name, property] of Object.entries(value.properties)) {
      value.properties[name] = sanitizeSchema(property)
    }
  }
  for (const key of SCHEMA_CHILD_KEYS) {
    if (key in value) value[key] = sanitizeSchema(value[key])
  }
  if ('additionalProperties' in value && typeof value.additionalProperties !== 'boolean') {
    value.additionalProperties = sanitizeSchema(value.additionalProperties)
  }
  if ('prefixItems' in value) value.prefixItems = sanitizeSchema(value.prefixItems)
  for (const key of DEFINITION_KEYS) sanitizeDefinitionTable(value, key)

  if ('const' in value) {
    value.enum = [value.const]
    delete value.const
  }

  const schemaTypes = normalizedSchemaTypes(value.type)
  if (schemaTypes.length === 0 && (typeof value.$ref === 'string' || hasComposition(value))) return value

  if (schemaTypes.length === 0) {
    if ('properties' in value || 'required' in value || 'additionalProperties' in value) {
      schemaTypes.push('object')
    } else if ('items' in value || 'prefixItems' in value) {
      schemaTypes.push('array')
    } else if ('enum' in value || 'format' in value) {
      schemaTypes.push('string')
    } else if (
      'minimum' in value ||
      'maximum' in value ||
      'exclusiveMinimum' in value ||
      'exclusiveMaximum' in value ||
      'multipleOf' in value
    ) {
      schemaTypes.push('number')
    } else {
      for (const key of Object.keys(value)) delete value[key]
      return value
    }
  }

  value.type = schemaTypes.length === 1 ? schemaTypes[0] : schemaTypes
  if (schemaTypes.includes('object') && !('properties' in value)) value.properties = {}
  if (schemaTypes.includes('array') && !('items' in value)) value.items = { type: 'string' }
  return value
}

function sanitizeDefinitionTable(parent: JSONObject, key: (typeof DEFINITION_KEYS)[number]): void {
  if (!(key in parent)) return
  const definitions = parent[key]
  if (!isObject(definitions)) {
    delete parent[key]
    return
  }
  for (const [name, definition] of Object.entries(definitions)) {
    definitions[name] = sanitizeSchema(definition)
  }
}

function normalizedSchemaTypes(value: unknown): string[] {
  if (typeof value === 'string') return SUPPORTED_TYPES.has(value) ? [value] : []
  if (!Array.isArray(value)) return []
  return value.filter((entry): entry is string => typeof entry === 'string' && SUPPORTED_TYPES.has(entry))
}

function projectSchema(value: unknown): JSONObject {
  if (!isObject(value)) throw new Error('schema must be an object')
  const output: JSONObject = {}

  copyTypedScalar(value, output, '$ref', 'string')
  if ('type' in value) {
    const types = normalizedSchemaTypes(value.type)
    if (types.length === 0) throw new Error('invalid schema type')
    output.type = Array.isArray(value.type) ? types : types[0]
  }
  copyTypedScalar(value, output, 'description', 'string')
  copyTypedScalar(value, output, 'encrypted', 'boolean')

  if ('enum' in value) {
    if (!Array.isArray(value.enum)) throw new Error('invalid enum')
    output.enum = value.enum
  }
  if ('items' in value) output.items = projectSchema(value.items)
  if ('properties' in value) {
    if (!isObject(value.properties)) throw new Error('invalid properties')
    output.properties = sortedObject(
      Object.entries(value.properties).map(([name, property]) => [name, projectSchema(property)])
    )
  }
  if ('required' in value) {
    if (!Array.isArray(value.required) || !value.required.every(entry => typeof entry === 'string')) {
      throw new Error('invalid required')
    }
    output.required = value.required
  }
  if ('additionalProperties' in value) {
    if (typeof value.additionalProperties === 'boolean') output.additionalProperties = value.additionalProperties
    else output.additionalProperties = projectSchema(value.additionalProperties)
  }
  for (const key of COMPOSITION_KEYS) {
    if (!(key in value)) continue
    const variants = value[key]
    if (!Array.isArray(variants)) throw new Error(`invalid ${key}`)
    output[key] = variants.map(projectSchema)
  }
  for (const key of DEFINITION_KEYS) {
    if (!(key in value)) continue
    const definitions = value[key]
    if (!isObject(definitions)) throw new Error(`invalid ${key}`)
    output[key] = sortedObject(
      Object.entries(definitions).map(([name, definition]) => [name, projectSchema(definition)])
    )
  }

  return output
}

function copyTypedScalar(source: JSONObject, target: JSONObject, key: string, type: 'string' | 'boolean'): void {
  if (!(key in source)) return
  if (typeof source[key] !== type) throw new Error(`invalid ${key}`)
  target[key] = source[key]
}

function pruneUnreachableDefinitions(schema: JSONObject): void {
  const reachable = new Set<string>()
  const pending: Array<{ table: string; name: string }> = []
  collectRefsOutsideDefinitions(schema, pending)

  while (pending.length > 0) {
    const pointer = pending.pop()!
    const identity = `${pointer.table}\0${pointer.name}`
    if (reachable.has(identity)) continue
    reachable.add(identity)
    const definitions = schema[pointer.table]
    if (isObject(definitions) && pointer.name in definitions) collectRefs(definitions[pointer.name], pending)
  }

  for (const table of DEFINITION_KEYS) {
    const definitions = schema[table]
    if (!isObject(definitions)) continue
    for (const name of Object.keys(definitions)) {
      if (!reachable.has(`${table}\0${name}`)) delete definitions[name]
    }
    if (Object.keys(definitions).length === 0) delete schema[table]
  }
}

function collectRefsOutsideDefinitions(value: unknown, pending: Array<{ table: string; name: string }>): void {
  if (Array.isArray(value)) {
    for (const child of value) collectRefsOutsideDefinitions(child, pending)
    return
  }
  if (!isObject(value)) return
  collectRef(value, pending)
  forEachSchemaChild(value, false, child => collectRefsOutsideDefinitions(child, pending))
}

function collectRefs(value: unknown, pending: Array<{ table: string; name: string }>): void {
  if (Array.isArray(value)) {
    for (const child of value) collectRefs(child, pending)
    return
  }
  if (!isObject(value)) return
  collectRef(value, pending)
  for (const child of Object.values(value)) collectRefs(child, pending)
}

function collectRef(value: JSONObject, pending: Array<{ table: string; name: string }>): void {
  if (typeof value.$ref !== 'string') return
  const pointer = localDefinitionPointer(value.$ref)
  if (pointer) pending.push(pointer)
}

function localDefinitionPointer(reference: string): { table: string; name: string } | undefined {
  if (!reference.startsWith('#')) return undefined
  try {
    const fragment = decodeURIComponent(reference.slice(1))
    const parts = fragment
      .split('/')
      .slice(1)
      .map(part => part.replaceAll('~1', '/').replaceAll('~0', '~'))
    if (parts.length < 2 || !DEFINITION_KEYS.includes(parts[0] as (typeof DEFINITION_KEYS)[number])) return undefined
    return { table: parts[0]!, name: parts[1]! }
  } catch {
    return undefined
  }
}

function compactLargeSchema(schema: JSONObject): void {
  const passes = [stripDescriptions, dropDefinitions, collapseDeepSchemas, pruneCompositions]
  for (const pass of passes) {
    if (normalizedSchemaByteLength(schema) <= MAX_COMPACT_SCHEMA_BYTES) break
    pass(schema)
  }
}

function normalizedSchemaByteLength(schema: JSONObject): number {
  try {
    return Buffer.byteLength(JSON.stringify(projectSchema(schema)), 'utf8')
  } catch {
    return 0
  }
}

function stripDescriptions(value: unknown): void {
  if (Array.isArray(value)) {
    for (const child of value) stripDescriptions(child)
    return
  }
  if (!isObject(value)) return
  delete value.description
  forEachSchemaChild(value, true, stripDescriptions)
}

function dropDefinitions(schema: JSONObject): void {
  rewriteDefinitionRefs(schema)
  for (const key of DEFINITION_KEYS) delete schema[key]
}

function rewriteDefinitionRefs(value: unknown): void {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const child = value[index]
      if (isObject(child) && typeof child.$ref === 'string' && localDefinitionPointer(child.$ref)) value[index] = {}
      else rewriteDefinitionRefs(child)
    }
    return
  }
  if (!isObject(value)) return
  if (typeof value.$ref === 'string' && localDefinitionPointer(value.$ref)) {
    for (const key of Object.keys(value)) delete value[key]
    return
  }
  forEachSchemaChildEntry(value, false, (parent, key, child) => {
    if (isObject(child) && typeof child.$ref === 'string' && localDefinitionPointer(child.$ref)) {
      assignSchemaChild(parent, key, {})
    } else rewriteDefinitionRefs(child)
  })
}

function collapseDeepSchemas(schema: JSONObject): void {
  collapseDeepSchema(schema, 0)
}

function collapseDeepSchema(value: unknown, depth: number): void {
  if (Array.isArray(value)) {
    for (const child of value) collapseDeepSchema(child, depth)
    return
  }
  if (!isObject(value)) return
  forEachSchemaChildEntry(value, false, (parent, key, child) => {
    if (depth + 1 >= MAX_COMPACT_SCHEMA_DEPTH && isObject(child) && isComplexSchema(child)) {
      assignSchemaChild(parent, key, {})
    } else collapseDeepSchema(child, depth + 1)
  })
}

function pruneCompositions(value: unknown): void {
  if (Array.isArray(value)) {
    for (const child of value) pruneCompositions(child)
    return
  }
  if (!isObject(value)) return
  if (hasComposition(value)) {
    for (const key of Object.keys(value)) delete value[key]
    return
  }
  forEachSchemaChildEntry(value, false, (parent, key, child) => {
    if (isObject(child) && hasComposition(child)) assignSchemaChild(parent, key, {})
    else pruneCompositions(child)
  })
}

function forEachSchemaChild(value: JSONObject, includeDefinitions: boolean, visit: (child: unknown) => void): void {
  if (isObject(value.properties)) {
    for (const child of Object.values(value.properties)) visit(child)
  }
  for (const key of SCHEMA_CHILD_KEYS) if (key in value) visit(value[key])
  if ('additionalProperties' in value && typeof value.additionalProperties !== 'boolean') {
    visit(value.additionalProperties)
  }
  if (!includeDefinitions) return
  for (const key of DEFINITION_KEYS) {
    if (isObject(value[key])) for (const child of Object.values(value[key])) visit(child)
  }
}

function forEachSchemaChildEntry(
  value: JSONObject,
  includeDefinitions: boolean,
  visit: (parent: JSONObject | unknown[], key: string | number, child: unknown) => void
): void {
  if (isObject(value.properties)) {
    for (const [key, child] of Object.entries(value.properties)) visit(value.properties, key, child)
  }
  for (const key of SCHEMA_CHILD_KEYS) {
    if (!(key in value)) continue
    const child = value[key]
    if (Array.isArray(child)) {
      for (let index = 0; index < child.length; index += 1) visit(child, index, child[index])
    } else {
      visit(value, key, child)
    }
  }
  if ('additionalProperties' in value && typeof value.additionalProperties !== 'boolean') {
    visit(value, 'additionalProperties', value.additionalProperties)
  }
  if (!includeDefinitions) return
  for (const key of DEFINITION_KEYS) {
    if (!isObject(value[key])) continue
    for (const [name, child] of Object.entries(value[key])) visit(value[key], name, child)
  }
}

function assignSchemaChild(parent: JSONObject | unknown[], key: string | number, value: unknown): void {
  if (Array.isArray(parent)) {
    if (typeof key !== 'number') throw new Error('array schema child requires a numeric index')
    parent[key] = value
    return
  }
  parent[String(key)] = value
}

function hasComposition(value: JSONObject): boolean {
  return COMPOSITION_KEYS.some(key => key in value)
}

function isComplexSchema(value: JSONObject): boolean {
  return (
    SCHEMA_CHILD_KEYS.some(key => key in value) ||
    'properties' in value ||
    'additionalProperties' in value ||
    '$ref' in value
  )
}

function sortedObject(entries: Array<[string, unknown]>): JSONObject {
  return Object.fromEntries(entries.sort(([left], [right]) => compareCodePointStrings(left, right)))
}

function isObject(value: unknown): value is JSONObject {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}
