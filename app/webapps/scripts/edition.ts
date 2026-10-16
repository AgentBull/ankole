import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  existsSync,
  readFileSync,
  readdirSync,
  mkdirSync,
  rmSync,
  writeFileSync,
  symlinkSync,
  realpathSync
} from 'node:fs'

export const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..')
export const edition = process.env.ANKOLE_EDITION ?? 'foss'
if (edition !== 'foss' && edition !== 'saas') throw new Error('ANKOLE_EDITION must be foss or saas')

export const artifactRoot = path.join(repositoryRoot, 'app/control_plane/_build', edition)
export const localeDirectory = path.join(artifactRoot, 'locales')
export const assetsDirectory = path.join(artifactRoot, 'webapps/assets')

export function webappEntries(): Record<string, string> {
  const publicRoot = path.join(repositoryRoot, 'app/webapps')
  const entries = readEntries(publicRoot)
  if (edition === 'saas') {
    const privateRoot = path.join(repositoryRoot, 'internals/webapps')
    const privateEntries = readEntries(privateRoot)
    for (const [name, file] of Object.entries(privateEntries)) {
      if (name in entries) throw new Error(`Duplicate webapp entry: ${name}`)
      entries[name] = file
    }
  }
  return entries
}

export function prepareEdition(): void {
  if (edition === 'saas') {
    const sharedDependencies = path.join(repositoryRoot, 'app/webapps/node_modules')
    const privateDependencies = path.join(repositoryRoot, 'internals/webapps/node_modules')
    try {
      symlinkSync(sharedDependencies, privateDependencies, 'dir')
    } catch (error) {
      if (!(error instanceof Error && 'code' in error && error.code === 'EEXIST')) throw error
    }
    if (realpathSync(privateDependencies) !== realpathSync(sharedDependencies)) {
      throw new Error('SaaS webapps must use app/webapps/node_modules')
    }
  }
  webappEntries()
  prepareLocales()
}

function readEntries(root: string): Record<string, string> {
  const entries: unknown = JSON.parse(readFileSync(path.join(root, 'entries.json'), 'utf8'))
  if (!entries || typeof entries !== 'object' || Array.isArray(entries)) throw new Error('Invalid webapp entries')
  return Object.fromEntries(
    Object.entries(entries).map(([name, relative]) => {
      if (!/^[a-z][a-z0-9-]*$/.test(name) || typeof relative !== 'string') throw new Error('Invalid webapp entry')
      const file = path.resolve(root, relative)
      if (!file.startsWith(root + path.sep) || !existsSync(file)) throw new Error(`Missing webapp entry: ${file}`)
      return [name, file]
    })
  )
}

/** Both Phoenix and Vite read these generated catalogs; source files stay unchanged. */
export function prepareLocales(): void {
  const catalogs = new Map<string, Record<string, unknown>>()
  const roots = [path.join(repositoryRoot, 'app/locales')]
  if (edition === 'saas') roots.push(path.join(repositoryRoot, 'internals/locales'))
  for (const root of roots) {
    for (const file of readdirSync(root)
      .filter(file => file.endsWith('.toml'))
      .sort()) {
      const locale = path.basename(file, '.toml')
      const source = Bun.TOML.parse(readFileSync(path.join(root, file), 'utf8'))
      if (!table(source)) throw new Error(`Invalid locale catalog: ${file}`)
      const target = catalogs.get(locale) ?? {}
      mergeCatalog(target, source, `${locale}:`)
      catalogs.set(locale, target)
    }
  }
  mkdirSync(localeDirectory, { recursive: true })
  const expected = new Set([...catalogs.keys()].map(locale => `${locale}.json`))
  for (const file of readdirSync(localeDirectory)) {
    if (!expected.has(file)) rmSync(path.join(localeDirectory, file))
  }
  for (const [locale, catalog] of catalogs) {
    const file = path.join(localeDirectory, `${locale}.json`)
    const text = `${JSON.stringify(catalog)}\n`
    if (!existsSync(file) || readFileSync(file, 'utf8') !== text) writeFileSync(file, text)
  }
}

function mergeCatalog(target: Record<string, unknown>, source: Record<string, unknown>, prefix: string): void {
  for (const [key, value] of Object.entries(source)) {
    if (!(key in target)) target[key] = value
    else if (table(target[key]) && table(value) && target[key].__mf2__ !== true && value.__mf2__ !== true) {
      mergeCatalog(target[key], value, `${prefix}${key}.`)
    } else throw new Error(`Duplicate locale key: ${prefix}${key}`)
  }
}

function table(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
}
