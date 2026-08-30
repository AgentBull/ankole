import { readFile, readdir } from 'node:fs/promises'
import { join, relative, sep } from 'node:path'

const DIST_DIR = join(import.meta.dirname, '..', 'dist')
const INTERNAL_ORIGIN = 'https://ankole.invalid'

const HTML_ENTITIES = {
  amp: '&',
  apos: "'",
  gt: '>',
  lt: '<',
  nbsp: '\u00a0',
  quot: '"'
}

function decodeHtmlEntities(value) {
  return value.replace(/&(#(?:x[\da-f]+|\d+)|amp|apos|gt|lt|nbsp|quot);/gi, (entity, name) => {
    if (!name.startsWith('#')) return HTML_ENTITIES[name.toLowerCase()]

    const radix = name[1].toLowerCase() === 'x' ? 16 : 10
    const digits = radix === 16 ? name.slice(2) : name.slice(1)
    const codePoint = Number.parseInt(digits, radix)

    return codePoint <= 0x10ffff ? String.fromCodePoint(codePoint) : entity
  })
}

async function listFiles(directory) {
  const entries = await readdir(directory, { withFileTypes: true })
  const files = await Promise.all(
    entries.map(entry => {
      const path = join(directory, entry.name)
      return entry.isDirectory() ? listFiles(path) : [path]
    })
  )

  return files.flat()
}

function toDistPath(file) {
  return relative(DIST_DIR, file).split(sep).join('/')
}

function toPagePath(file) {
  if (file === 'index.html') return '/'
  if (file.endsWith('/index.html')) return `/${file.slice(0, -'index.html'.length)}`
  return `/${file}`
}

function extractAttributeValues(html, attribute) {
  const pattern = new RegExp(`(?:^|[\\s<])${attribute}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'=<>\u0060]+))`, 'gi')

  return [...html.matchAll(pattern)].map(match => decodeHtmlEntities(match[1] ?? match[2] ?? match[3]))
}

function serializedString(value) {
  if (typeof value === 'string') return value
  if (Array.isArray(value) && value[0] === 0 && typeof value[1] === 'string') return value[1]
  return null
}

function collectSerializedHrefs(value, hrefs) {
  if (Array.isArray(value)) {
    for (const item of value) collectSerializedHrefs(item, hrefs)
    return
  }

  if (value === null || typeof value !== 'object') return

  for (const [key, item] of Object.entries(value)) {
    if (key === 'href') {
      const href = serializedString(item)
      if (href !== null) hrefs.push(href)
    }
    collectSerializedHrefs(item, hrefs)
  }
}

function extractIslandHrefs(html, source) {
  const hrefs = []

  for (const match of html.matchAll(/<astro-island\b[^>]*>/gi)) {
    const props = match[0].match(/(?:^|\s)props\s*=\s*(?:"([^"]*)"|'([^']*)')/i)
    if (props === null) continue

    try {
      collectSerializedHrefs(JSON.parse(decodeHtmlEntities(props[1] ?? props[2])), hrefs)
    } catch (error) {
      throw new Error(`Cannot parse Astro island properties in ${source}`, { cause: error })
    }
  }

  return hrefs
}

function targetFile(pathname, distFiles) {
  const path = pathname.replace(/^\/+/, '')
  const candidates = path === '' || pathname.endsWith('/') ? [`${path}index.html`] : [path, `${path}/index.html`]

  return candidates.find(candidate => distFiles.has(candidate)) ?? null
}

function decodedUrlPart(value, description) {
  try {
    return { value: decodeURIComponent(value) }
  } catch {
    return { error: `${description} has invalid percent encoding` }
  }
}

function anchorFrom(url) {
  const rawAnchor = url.hash.slice(1).split(':~:text=')[0]
  if (rawAnchor === '') return { value: null }
  return decodedUrlPart(rawAnchor, 'anchor')
}

function isInternalHref(href) {
  return !href.startsWith('//') && !/^[a-z][a-z\d+.-]*:/i.test(href)
}

async function main() {
  const files = (await listFiles(DIST_DIR)).sort((left, right) => toDistPath(left).localeCompare(toDistPath(right)))
  const distFiles = new Set(files.map(toDistPath))
  const htmlFiles = files.filter(file => file.endsWith('.html'))
  const htmlByPath = new Map(
    await Promise.all(htmlFiles.map(async file => [toDistPath(file), await readFile(file, 'utf8')]))
  )
  const idsByPath = new Map([...htmlByPath].map(([path, html]) => [path, new Set(extractAttributeValues(html, 'id'))]))
  const failures = []
  let internalHrefCount = 0

  for (const [source, html] of htmlByPath) {
    const hrefs = new Set(
      [...extractAttributeValues(html, 'href'), ...extractIslandHrefs(html, source)].map(href => href.trim())
    )
    const base = `${INTERNAL_ORIGIN}${toPagePath(source)}`

    for (const href of hrefs) {
      if (!isInternalHref(href)) continue

      let url
      try {
        url = new URL(href, base)
      } catch {
        failures.push({ source, href, reason: 'target is not a valid URL' })
        internalHrefCount += 1
        continue
      }

      if (url.origin !== INTERNAL_ORIGIN) continue
      internalHrefCount += 1

      const decodedPath = decodedUrlPart(url.pathname, 'path')
      if (decodedPath.error !== undefined) {
        failures.push({ source, href, reason: decodedPath.error })
        continue
      }

      const target = targetFile(decodedPath.value, distFiles)
      if (target === null) {
        failures.push({ source, href, reason: `target ${decodedPath.value} does not exist` })
        continue
      }

      const anchor = anchorFrom(url)
      if (anchor.error !== undefined) {
        failures.push({ source, href, reason: anchor.error })
        continue
      }

      if (anchor.value !== null && !idsByPath.get(target)?.has(anchor.value)) {
        failures.push({
          source,
          href,
          reason: `id ${JSON.stringify(anchor.value)} does not exist in ${target}`
        })
      }
    }
  }

  if (failures.length > 0) {
    console.error(`Internal link check failed with ${failures.length} invalid href(s):`)
    for (const failure of failures) {
      console.error(`  - ${failure.source} -> ${JSON.stringify(failure.href)} (${failure.reason})`)
    }
    process.exitCode = 1
    return
  }

  process.stdout.write(
    `Internal link check passed across ${htmlFiles.length} HTML file(s) and ${internalHrefCount} internal href(s).\n`
  )
}

try {
  await main()
} catch (error) {
  const message = error instanceof Error ? error.message : String(error)
  console.error(`Internal link check failed: ${message}`)
  process.exitCode = 1
}
