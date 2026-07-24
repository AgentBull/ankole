import { readdirSync, readFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

type Product = (typeof products)[number]

type Playbook = {
  name: string
  description: string
  products: Product[]
  path: string
}

const products = ['docx', 'pptx', 'xlsx'] as const

const product = requestedProduct(Bun.argv[2])
const root = Bun.argv[3] ?? join(import.meta.dir, '..', 'playbooks')
const playbooks = discoverPlaybooks(root).filter(playbook => playbook.products.includes(product))

if (playbooks.length === 0) {
  process.stdout.write(`No Playbook applies to ${product}.\n`)
} else {
  process.stdout.write(`Playbooks for ${product}:\n`)
  for (const playbook of playbooks) {
    process.stdout.write(`- ${playbook.name} (${playbook.path}): ${playbook.description}\n`)
  }
}

function requestedProduct(value: string | undefined): Product {
  if (!isProduct(value)) {
    process.stderr.write(`usage: bun list_playbooks.ts <${products.join('|')}> [playbooks-root]\n`)
    process.exit(2)
  }
  return value
}

function discoverPlaybooks(root: string): Playbook[] {
  const playbooks = markdownFiles(root).map(path => readPlaybook(path))
  const names = new Set<string>()

  for (const playbook of playbooks) {
    if (names.has(playbook.name)) throw new Error(`duplicate Playbook name: ${playbook.name}`)
    names.add(playbook.name)
  }

  return playbooks.sort((left, right) => left.path.localeCompare(right.path))
}

function markdownFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap(entry => {
    const path = join(directory, entry.name)
    if (entry.isDirectory()) return markdownFiles(path)
    if (entry.isFile() && entry.name.endsWith('.md')) return [path]
    return []
  })
}

function readPlaybook(path: string): Playbook {
  const absolutePath = resolve(path)
  const content = readFileSync(path, 'utf8')
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/)
  if (!match) throw new Error(`${absolutePath}: missing YAML front matter`)

  const parsed = Bun.YAML.parse(match[1]!)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${absolutePath}: YAML front matter must be a mapping`)
  }
  const metadata = parsed as Record<string, unknown>
  const name = requiredString(metadata, 'name', absolutePath)
  const description = requiredString(metadata, 'description', absolutePath)
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name)) {
    throw new Error(`${absolutePath}: name must use lowercase kebab-case`)
  }

  return { name, description, products: requiredProducts(metadata, absolutePath), path: absolutePath }
}

function requiredString(metadata: Record<string, unknown>, key: string, path: string): string {
  const value = metadata[key]
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`${path}: ${key} must be a non-empty string`)
  }
  return value.trim()
}

function requiredProducts(metadata: Record<string, unknown>, path: string): Product[] {
  const value = metadata['products']
  if (!Array.isArray(value) || value.length === 0) {
    throw new Error(`${path}: products must list at least one of ${products.join(', ')}`)
  }
  for (const entry of value) {
    if (!isProduct(entry)) throw new Error(`${path}: unknown product ${String(entry)}`)
  }
  const selected = value as Product[]
  if (new Set(selected).size !== selected.length) throw new Error(`${path}: products must not repeat a value`)
  return selected
}

function isProduct(value: unknown): value is Product {
  return typeof value === 'string' && (products as readonly string[]).includes(value)
}
