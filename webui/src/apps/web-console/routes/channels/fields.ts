// Helpers for rendering an adapter's `form_schema` into a config form.
//
// Each adapter ships a form schema describing its source fields (paths, kinds,
// options). Field paths are rooted at "source" (e.g. ["source", "app_id"]); the
// form state itself is just the source object, so we index it with path.slice(1).

export type FieldKind = "text" | "secret" | "select" | "boolean" | "callback_url"

export type FormField = {
  path: string[]
  kind: FieldKind
  required?: boolean
  options?: string[]
  ui?: { group?: string }
}

export type FormSchema = {
  adapter_id?: string
  label?: string
  channel_kind?: string
  help_url?: string
  default_source?: Record<string, unknown>
  sections?: Array<{ key?: string; fields?: FormField[] }>
}

export type SourceValues = Record<string, unknown>

export function asFormSchema(value: unknown): FormSchema {
  return (value ?? {}) as FormSchema
}

export function schemaFields(schema: FormSchema): FormField[] {
  return (schema.sections ?? []).flatMap(section => section.fields ?? [])
}

export function sourceFieldPath(field: FormField): string[] {
  return field.path[0] === "source" ? field.path.slice(1) : field.path
}

export function getPath(source: SourceValues | undefined, path: string[]): unknown {
  return path.reduce<unknown>((acc, key) => {
    if (acc && typeof acc === "object") {
      return (acc as Record<string, unknown>)[key]
    }
    return undefined
  }, source)
}

export function setPath(source: SourceValues, path: string[], value: unknown): SourceValues {
  const [head, ...rest] = path
  if (rest.length === 0) {
    return { ...source, [head]: value }
  }
  const child = source[head]
  const childObject = child && typeof child === "object" ? (child as SourceValues) : {}
  return { ...source, [head]: setPath(childObject, rest, value) }
}

const FIELD_LABELS: Record<string, string> = {
  id: "Source ID",
  enabled: "Enabled",
  app_id: "App ID",
  app_secret: "App secret",
  application_id: "Application ID",
  bot_token: "Bot token",
  bot_username: "Bot username",
  client_secret: "Client secret",
  domain: "Domain",
  app_type: "App type",
  web_login_disabled: "Disable web login",
  group_message_mode: "Group message mode",
  redirect_uri: "Redirect URI",
  start_transport: "Start transport",
  tenant_key: "Tenant key",
}

export function fieldLabel(field: FormField): string {
  const last = field.path[field.path.length - 1]
  // oidc.enabled / oauth2.enabled
  if (last === "enabled" && field.path.length > 2) {
    return "OAuth enabled"
  }
  return FIELD_LABELS[last] ?? humanize(last)
}

export function isSourceIdField(field: FormField): boolean {
  return field.path.length === 2 && field.path[0] === "source" && field.path[1] === "id"
}

// A callback_url field lives under its provider object, e.g.
// ["source", "oidc", "callback_url"] -> provider key "oidc".
export function callbackProviderKey(field: FormField): string | undefined {
  return field.path.length >= 3 ? field.path[1] : undefined
}

export function callbackEnabled(source: SourceValues, field: FormField): boolean {
  const key = callbackProviderKey(field)
  if (!key) {
    return false
  }
  const provider = source[key]
  const enabled = provider && typeof provider === "object" ? (provider as Record<string, unknown>).enabled : undefined
  return enabled !== false
}

export function buildCallbackUrl(template: string | undefined, sourceId: unknown): string {
  const id = typeof sourceId === "string" ? sourceId.trim() : ""
  if (!template || id === "") {
    return ""
  }
  return template.replace("__source_id__", encodeURIComponent(id))
}

export function humanizeOption(option: string): string {
  return humanize(option)
}

export function secretPresent(config: SourceValues | undefined, field: FormField): boolean {
  const status = getPath(config, sourceFieldPath(field))
  return Boolean(status && typeof status === "object" && (status as Record<string, unknown>).present)
}

function humanize(value: string): string {
  return value
    .split(/[_-]/)
    .filter(Boolean)
    .map(part => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ")
}
