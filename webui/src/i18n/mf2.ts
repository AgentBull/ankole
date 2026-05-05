import { MessageFormat } from "messageformat"

const canonicalTags = new Map([
  ["bold", "strong"],
  ["b", "strong"],
  ["strong", "strong"],
  ["i", "em"],
  ["italic", "em"],
  ["em", "em"],
  ["br", "br"],
  ["u", "u"],
  ["s", "s"],
  ["code", "code"],
  ["small", "small"],
])

const reactBasicTags = ["strong", "em", "br", "u", "s", "code", "small"]

const reservedOptions = new Set([
  "appendNamespaceToMissingKey",
  "context",
  "count",
  "defaultValue",
  "fallbackLng",
  "i18nResolved",
  "interpolation",
  "joinArrays",
  "keyPrefix",
  "lng",
  "lngs",
  "ns",
  "ordinal",
  "postProcess",
  "replace",
  "returnDetails",
  "returnObjects",
])

const compiledMessages = new Map<string, MessageFormat>()

export const Mf2PostProcessor = {
  type: "postProcessor",
  name: "mf2",
  process(value: unknown, _key: string | string[], options: Record<string, unknown>, translator: unknown) {
    if (typeof value !== "string") return value

    return formatMf2(value, localeFromOptions(options, translator), valuesFromOptions(options))
  },
}

export const Mf2ReactPreset = {
  type: "3rdParty",
  init(instance: { options: { react?: Record<string, unknown> } }) {
    const reactOptions = instance.options.react || {}
    const keepBasicHtmlNodesFor = reactOptions.transKeepBasicHtmlNodesFor

    instance.options.react = {
      ...reactOptions,
      transSupportBasicHtmlNodes: true,
      transKeepBasicHtmlNodesFor: [
        ...new Set([...(Array.isArray(keepBasicHtmlNodesFor) ? keepBasicHtmlNodesFor : []), ...reactBasicTags]),
      ],
    }
  },
}

export function clearMf2CacheForTest() {
  compiledMessages.clear()
}

export function mf2CacheSizeForTest() {
  return compiledMessages.size
}

export function formatMf2ForTest(source: string, values: Record<string, unknown>, lng = "en-US") {
  return formatMf2(source, lng, values)
}

function formatMf2(source: string, lng: string, values: Record<string, unknown>) {
  try {
    const message = compiledMessage(lng, source)
    const parts = message.formatToParts(values, error => {
      throw error
    })

    return renderParts(parts)
  } catch {
    return curlyTagsToHtml(source)
  }
}

function compiledMessage(lng: string, source: string) {
  const cacheKey = `${lng}__${source}`
  const cached = compiledMessages.get(cacheKey)

  if (cached) return cached

  const message = new MessageFormat(lng, source)
  compiledMessages.set(cacheKey, message)

  return message
}

function renderParts(parts: Array<Record<string, unknown>>) {
  return parts.map(renderPart).join("")
}

function renderPart(part: Record<string, unknown>) {
  if (part.type === "text" || part.type === "bidiIsolation") {
    return escapeHtml(part.value)
  }

  if (part.type === "markup") {
    return renderMarkup(part)
  }

  if (Array.isArray(part.parts)) {
    return part.parts.map(subpart => escapeHtml(subpart.value)).join("")
  }

  if (part.type === "fallback" && typeof part.source === "string") {
    return escapeHtml(`{${part.source}}`)
  }

  return escapeHtml(part.value)
}

function renderMarkup(part: Record<string, unknown>) {
  const tag = canonicalTag(part.name)

  if (!tag) return ""

  if (part.kind === "close") return `</${tag}>`
  if (part.kind === "standalone") return tag === "br" ? "<br/>" : `<${tag}></${tag}>`

  return `<${tag}>`
}

function curlyTagsToHtml(source: string) {
  return escapeHtml(source)
    .replace(/\{#\s*([A-Za-z][\w-]*)(?:\s+[^}]*)?\}/g, (match, name) => {
      const tag = canonicalTag(name)
      return tag ? `<${tag}>` : match
    })
    .replace(/\{\/\s*([A-Za-z][\w-]*)\s*\}/g, (match, name) => {
      const tag = canonicalTag(name)
      return tag ? `</${tag}>` : match
    })
}

function canonicalTag(name: unknown) {
  return typeof name === "string" ? canonicalTags.get(name) : undefined
}

function localeFromOptions(options: Record<string, unknown> = {}, translator: unknown) {
  if (typeof options.lng === "string") return options.lng

  if (Array.isArray(options.lngs) && typeof options.lngs[0] === "string") {
    return options.lngs[0]
  }

  if (hasLanguage(translator)) return translator.language

  return "en-US"
}

function valuesFromOptions(options: Record<string, unknown> = {}) {
  if (isRecord(options.values)) return options.values

  return Object.entries(options).reduce<Record<string, unknown>>((values, [key, value]) => {
    if (reservedOptions.has(key) || key.startsWith("defaultValue")) return values

    values[key] = value
    return values
  }, {})
}

function hasLanguage(value: unknown): value is { language: string } {
  return isRecord(value) && typeof value.language === "string"
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
}

function escapeHtml(value: unknown) {
  return String(value ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;")
}
