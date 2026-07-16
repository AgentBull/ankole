export type StrictOutputSchemaIssue = {
  path: Array<string | number>
  message: string
}

const unsupportedKeywords = [
  'allOf',
  'oneOf',
  'not',
  'dependentRequired',
  'dependentSchemas',
  'if',
  'then',
  'else'
] as const

const supportedTypes = new Set(['string', 'number', 'boolean', 'integer', 'object', 'array', 'null'])

export function strictOutputSchemaIssues(schema: Record<string, unknown>): StrictOutputSchemaIssue[] {
  const issues: StrictOutputSchemaIssue[] = []

  if (schema.type !== 'object') {
    issues.push({ path: ['type'], message: 'task_worker output_schema root type must be object' })
  }
  if ('anyOf' in schema) {
    issues.push({ path: ['anyOf'], message: 'task_worker output_schema root must not use anyOf' })
  }

  visitSchema(schema, [], issues)
  return issues
}

function visitSchema(schema: unknown, path: Array<string | number>, issues: StrictOutputSchemaIssue[]): void {
  if (!isJSONObject(schema)) {
    issues.push({ path, message: 'output_schema entries must be JSON Schema objects' })
    return
  }

  for (const keyword of unsupportedKeywords) {
    if (keyword in schema) {
      issues.push({ path: [...path, keyword], message: `task_worker output_schema does not support ${keyword}` })
    }
  }

  validateType(schema.type, [...path, 'type'], issues)

  const hasObjectType =
    schema.type === 'object' || (Array.isArray(schema.type) && schema.type.some(type => type === 'object'))
  if (
    !hasObjectType &&
    (schema.properties !== undefined || schema.required !== undefined || schema.additionalProperties !== undefined)
  ) {
    issues.push({ path: [...path, 'type'], message: 'output_schema with object keywords must use object type' })
  }
  if (hasObjectType) validateObjectSchema(schema, path, issues)

  const hasArrayType =
    schema.type === 'array' || (Array.isArray(schema.type) && schema.type.some(type => type === 'array'))
  if (hasArrayType && schema.items === undefined) {
    issues.push({ path: [...path, 'items'], message: 'every array output_schema must declare items' })
  }
  if (schema.items !== undefined) visitSchema(schema.items, [...path, 'items'], issues)
  visitSchemaArray(schema.anyOf, [...path, 'anyOf'], issues)
  visitDefinitions(schema.$defs, [...path, '$defs'], issues)
  visitDefinitions(schema.definitions, [...path, 'definitions'], issues)
}

function validateObjectSchema(
  schema: Record<string, unknown>,
  path: Array<string | number>,
  issues: StrictOutputSchemaIssue[]
): void {
  const properties = schema.properties
  if (!isJSONObject(properties)) {
    issues.push({ path: [...path, 'properties'], message: 'every object output_schema must declare properties' })
    return
  }

  if (schema.additionalProperties !== false) {
    issues.push({
      path: [...path, 'additionalProperties'],
      message: 'every object output_schema must set additionalProperties to false'
    })
  }

  const required = schema.required
  if (!Array.isArray(required) || required.some(key => typeof key !== 'string')) {
    issues.push({
      path: [...path, 'required'],
      message: 'every object output_schema must declare required as a string array containing every property'
    })
  } else {
    const requiredKeys = new Set(required)
    const propertyKeys = Object.keys(properties)
    const missing = propertyKeys.filter(key => !requiredKeys.has(key))
    if (missing.length > 0) {
      issues.push({
        path: [...path, 'required'],
        message: `every object output_schema must require every property; missing: ${missing.join(', ')}`
      })
    }
    const propertyKeySet = new Set(propertyKeys)
    const undeclared = [...requiredKeys].filter(key => !propertyKeySet.has(key))
    if (undeclared.length > 0) {
      issues.push({
        path: [...path, 'required'],
        message: `object output_schema required contains undeclared properties: ${undeclared.join(', ')}`
      })
    }
    if (requiredKeys.size !== required.length) {
      issues.push({ path: [...path, 'required'], message: 'object output_schema required keys must be unique' })
    }
  }

  for (const [key, propertySchema] of Object.entries(properties)) {
    visitSchema(propertySchema, [...path, 'properties', key], issues)
  }
}

function validateType(type: unknown, path: Array<string | number>, issues: StrictOutputSchemaIssue[]): void {
  if (type === undefined) return
  const types = Array.isArray(type) ? type : [type]
  if (types.length === 0 || types.some(value => typeof value !== 'string' || !supportedTypes.has(value))) {
    issues.push({ path, message: 'output_schema type contains an unsupported value' })
    return
  }
  if (Array.isArray(type) && (types.length !== 2 || !types.includes('null') || new Set(types).size !== 2)) {
    issues.push({ path, message: 'output_schema type arrays must contain one value type plus null' })
  }
}

function visitSchemaArray(value: unknown, path: Array<string | number>, issues: StrictOutputSchemaIssue[]): void {
  if (value === undefined) return
  if (!Array.isArray(value) || value.length === 0) {
    issues.push({ path, message: 'output_schema anyOf must be a non-empty array' })
    return
  }
  value.forEach((schema, index) => visitSchema(schema, [...path, index], issues))
}

function visitDefinitions(value: unknown, path: Array<string | number>, issues: StrictOutputSchemaIssue[]): void {
  if (value === undefined) return
  if (!isJSONObject(value)) {
    issues.push({ path, message: 'output_schema definitions must be an object' })
    return
  }
  for (const [key, schema] of Object.entries(value)) visitSchema(schema, [...path, key], issues)
}

function isJSONObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}
