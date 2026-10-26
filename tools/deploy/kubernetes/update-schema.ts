/** Regenerate the native Pod/PVC schema used by Worker provider validation. */
import { resolve } from 'node:path'

type Schema = Record<string, unknown>
const version = 'v1.37.1'
const source = `https://raw.githubusercontent.com/kubernetes/kubernetes/${version}/api/openapi-spec/swagger.json`
const response = await fetch(source)
if (!response.ok) throw new Error(`Kubernetes schema: HTTP ${response.status}`)
const upstream = (await response.json()) as { definitions: Record<string, Schema> }
const definitions: Record<string, Schema> = {}

function copy(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(copy)
  if (!value || typeof value !== 'object') return value
  const schema = value as Schema
  if (typeof schema.$ref === 'string') {
    const name = schema.$ref.slice('#/definitions/'.length)
    if (!(name in definitions)) {
      definitions[name] = {}
      definitions[name] = copy(upstream.definitions[name]) as Schema
    }
    return { $ref: schema.$ref }
  }
  // Kubernetes quantities accept JSON numbers and strings. IntOrString
  // fields accept integral numbers and strings (for example named ports).
  if (schema.format === 'int-or-string') return { type: ['integer', 'string'] }
  const result: Schema = {}
  for (const [key, field] of Object.entries(schema)) {
    if (key === 'description' || key === 'format' || key.startsWith('x-')) continue
    result[key] = copy(field)
  }
  if (schema.type === 'object' && schema.properties) result.additionalProperties = false
  return result
}

for (const name of ['io.k8s.api.core.v1.PodTemplateSpec', 'io.k8s.api.core.v1.PersistentVolumeClaimSpec']) {
  copy({ $ref: `#/definitions/${name}` })
}
// The OpenAPI string representation omits the numeric Quantity alternative.
// Source: apimachinery/pkg/api/resource/quantity.go UnmarshalJSON.
definitions['io.k8s.apimachinery.pkg.api.resource.Quantity'] = { type: ['string', 'number'] }
const result = { $comment: `Generated from ${source} by tools/deploy/kubernetes/update-schema.ts.`, definitions }
const output = resolve(import.meta.dir, '../../../app/control_plane/priv/worker_provider_schemas/kubernetes.json')
await Bun.write(output, `${JSON.stringify(result, null, 2)}\n`)
process.stdout.write(`${output}\n`)
