import { mkdir } from 'node:fs/promises'
import { join } from 'node:path'

// Import full versioned JSON Schemas from the metadata API. The documentation
// UI omits references and unions, so it cannot own executable contracts. Keep
// the reviewed selection separate so upstream additions stay unpublished.
const root = import.meta.dir
const selection: Record<string, string[]> = await Bun.file(join(root, 'selection.json')).json()
const write = process.argv.includes('--write')
const names = Object.entries(selection).flatMap(([id, slugs]) =>
  slugs.map(slug => [slug, `${id}.${slug.slice(id.length + 1).toLowerCase()}`] as const)
)

function publicText(text: string) {
  const value = text
    .replaceAll('ZENDESK_GET_APPS_JOB_STATUS', 'ZENDESK_GET_JOB_STATUSES2')
    .replace(/ Do NOT use Composio internal IDs.*$/, '')
    .replace(/ Note: The \{region\} placeholder in the base URL.*$/, '')
  return names.reduce((description, [slug, name]) => description.replaceAll(slug, name), value)
}

type Schema = Record<string, any>
type Tool = {
  slug: string
  description: string
  input_parameters: Schema
  output_parameters: Schema
  tags: string[]
  scopes?: string[]
  is_deprecated: boolean
  version: string
}

// Provider metadata mixes alternative grants with required grants and contains
// legacy scope names. Publish one supported grant set for each operation.
// Scope owners: developers.google.com/calendar/api/auth,
// developer.calendly.com/docs/authentication/scopes, and Trello's OAuth 2.0
// client-configuration guide.
function scopes(id: string, tool: Tool): string[] {
  const declared = Array.isArray(tool.scopes) ? tool.scopes : []
  const name = tool.slug.slice(id.length + 1).toLowerCase()
  const read = tool.tags.includes('readOnlyHint')
  if (['figma', 'stripe', 'sentry', 'zendesk'].includes(id)) return []
  if (id === 'salesforce') return ['api']
  if (id === 'gitlab') return [read ? 'read_api' : 'api']
  if (id === 'google_analytics') {
    const chosen = ['analytics.readonly', 'analytics.edit', 'analytics'].find(scope =>
      declared.includes(`https://www.googleapis.com/auth/${scope}`)
    )
    return chosen ? [`https://www.googleapis.com/auth/${chosen}`] : []
  }
  if (id === 'googlecalendar') {
    if (declared.length === 0) return []
    const scope = ['list_buildings', 'list_calendar_resources'].includes(name)
      ? 'admin.directory.resource.calendar.readonly'
      : name.startsWith('acl_') && read
        ? 'calendar.acls.readonly'
        : read
          ? 'calendar.readonly'
          : 'calendar'
    return [`https://www.googleapis.com/auth/${scope}`]
  }
  if (id === 'trello') {
    // Nested resources and search may cross boards, members and workspaces.
    // One read/write grant set keeps those operations usable across that boundary.
    const required = ['read:board:trello', 'read:member:trello', 'read:organization:trello']
    if (!read) {
      required.push('write:board:trello', 'write:member:trello', 'write:organization:trello')
      if (name.includes('member')) {
        required.push('write:board:membership:trello', 'write:organization:membership:trello')
      }
    }
    return required
  }
  if (id === 'calendly') {
    const exact: Record<string, string> = {
      cancel_scheduled_event: 'scheduled_events:write',
      create_event_type: 'event_types:write',
      create_share: 'shares:write',
      get_event_type: 'event_types:read',
      get_event_type_availability: 'availability:read',
      get_group: 'groups:read',
      get_user: 'users:read',
      list_activity_log_entries: 'activity_log:read',
      list_event_type_available_times: 'event_types:read',
      list_event_type_memberships: 'event_types:read',
      list_event_types: 'event_types:read',
      list_organization_memberships: 'organizations:read',
      list_outgoing_communications: 'outgoing_communications:read',
      list_routing_forms: 'routing_forms:read',
      list_user_availability_schedules: 'availability:read',
      list_user_busy_times: 'availability:read',
      list_user_locations: 'locations:read',
      organization_invitation: 'organizations:write',
      post_invitee: 'scheduled_events:write',
      revoke_user_s_organization_invitation: 'organizations:write',
      update_event_type_availability: 'availability:write',
      who_am_i: 'users:read'
    }
    const required = exact[name] ? [exact[name]] : declared.filter(scope => scope !== 'default')
    if (required.length === 0) throw new Error(`Review required Calendly scopes for ${tool.slug}`)
    return required
  }
  return declared
}

function schema(value: Schema): Schema {
  if (typeof value === 'boolean') return value
  const result: Schema = {}
  for (const [key, item] of Object.entries(value)) {
    if (key === '$schema') continue
    if (['properties', 'patternProperties', '$defs', 'definitions'].includes(key)) {
      result[key] = Object.fromEntries(
        Object.entries(item as Schema)
          .filter(([name]) => name !== 'composio_execution_message')
          .map(([name, child]) => [name, schema(child)])
      )
    } else if (
      ['items', 'additionalProperties', 'not', 'if', 'then', 'else', 'contains', 'propertyNames'].includes(key) &&
      item &&
      typeof item === 'object'
    ) {
      result[key] = Array.isArray(item) ? item.map(child => schema(child)) : schema(item)
    } else if (['anyOf', 'oneOf', 'allOf', 'prefixItems'].includes(key)) {
      result[key] = (item as Schema[]).map(child => schema(child))
    } else if (key === 'examples') {
      result[key] = JSON.parse(JSON.stringify(item).replaceAll(/composio/gi, 'example'))
    } else if (key === 'required') {
      result[key] = (item as string[]).filter(name => name !== 'composio_execution_message')
    } else result[key] = key === 'description' && typeof item === 'string' ? publicText(item) : item
  }
  return result
}

export function toolSchemas(tool: Pick<Tool, 'input_parameters' | 'output_parameters'>): {
  input_schema: Schema
  output_schema: Schema
} {
  if (tool.input_parameters.type !== 'object' || !tool.output_parameters.properties?.data) {
    throw new Error('The metadata API must return full input and output JSON Schemas')
  }
  return {
    input_schema: schema(tool.input_parameters),
    output_schema: {
      type: 'object',
      ...Object.fromEntries(
        ['$defs', 'definitions']
          .filter(key => tool.output_parameters[key])
          .map(key => [key, schema(tool.output_parameters)[key]])
      ),
      properties: { result: schema(tool.output_parameters.properties.data) },
      required: ['result']
    }
  }
}

export function toolContract(id: string, version: string, tool: Tool) {
  if (tool.is_deprecated) throw new Error(`${tool.slug} is deprecated; review the selection.`)
  if (tool.version !== version) throw new Error(`${tool.slug} resolved ${tool.version}, expected ${version}`)
  return {
    name: tool.slug.slice(id.length + 1).toLowerCase(),
    slug: tool.slug,
    description: publicText(tool.description),
    ...toolSchemas(tool),
    scopes: scopes(id, tool),
    annotations: {
      readOnlyHint: tool.tags.includes('readOnlyHint'),
      idempotentHint: tool.tags.includes('readOnlyHint') || tool.tags.includes('idempotentHint'),
      destructiveHint: tool.tags.includes('destructiveHint'),
      openWorldHint: true
    }
  }
}

async function fetchTools(id: string, version: string, apiKey: string) {
  const tools = new Map<string, Tool>()
  let cursor: string | undefined
  do {
    const url = new URL('https://backend.composio.dev/api/v3/tools')
    url.searchParams.set('toolkit_slug', id)
    url.searchParams.set(`toolkit_versions[${id}]`, version)
    url.searchParams.set('limit', '1000')
    if (cursor) url.searchParams.set('cursor', cursor)
    const response = await fetch(url, { headers: { 'x-api-key': apiKey } })
    if (!response.ok) throw new Error(`${id} metadata: HTTP ${response.status}`)
    const payload = (await response.json()) as { items: Tool[]; next_cursor?: string }
    for (const tool of payload.items) tools.set(tool.slug, tool)
    cursor = payload.next_cursor || undefined
  } while (cursor)
  return tools
}

if (import.meta.main) {
  const apiKey = process.env.COMPOSIO_API_KEY
  if (!apiKey) throw new Error('Set COMPOSIO_API_KEY for read-only metadata synchronization.')
  await mkdir(join(root, 'catalog'), { recursive: true })
  for (const [id, selected] of Object.entries(selection)) {
    const path = join(root, 'catalog', `${id}.json`)
    const current = await Bun.file(path).json()
    const version: string = current.version
    const tools = await fetchTools(id, version, apiKey)
    const result = {
      source: 'https://backend.composio.dev/api/v3/tools',
      toolkit: id,
      version,
      tools: selected.map(slug => {
        const tool = tools.get(slug)
        if (!tool) throw new Error(`${slug} is missing; review the selection.`)
        return toolContract(id, version, tool)
      })
    }
    const content = `${JSON.stringify(result, null, 2)}\n`
    if (write) await Bun.write(path, content)
    else if (JSON.stringify(current) !== JSON.stringify(result)) {
      throw new Error(`${id} differs; review and run with --write.`)
    }
    process.stdout.write(`${id}: ${result.tools.length} tools, version ${result.version}\n`)
  }
}
