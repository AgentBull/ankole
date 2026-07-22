import { readdirSync, readFileSync } from 'node:fs'
import { join, relative, sep } from 'node:path'

type Playbook = {
  name: string
  description: string
  path: string
}

const defaultRoot = join(import.meta.dir, '..', 'playbooks')
const playbooks = discoverPlaybooks(Bun.argv[2] ?? defaultRoot)

process.stdout.write('Available Playbooks:\n')
for (const playbook of playbooks) {
  process.stdout.write(`- ${playbook.name} (${playbook.path}): ${playbook.description}\n`)
}

function discoverPlaybooks(root: string): Playbook[] {
  const playbooks = markdownFiles(root).map(path => readPlaybook(root, path))
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

function readPlaybook(root: string, path: string): Playbook {
  const content = readFileSync(path, 'utf8')
  const match = content.match(/^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/)
  if (!match) throw new Error(`${displayPath(root, path)}: missing YAML front matter`)

  const parsed = Bun.YAML.parse(match[1]!)
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error(`${displayPath(root, path)}: YAML front matter must be a mapping`)
  }
  const metadata = parsed as Record<string, unknown>
  const name = requiredString(metadata, 'name', root, path)
  const description = requiredString(metadata, 'description', root, path)
  if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(name)) {
    throw new Error(`${displayPath(root, path)}: name must use lowercase kebab-case`)
  }

  return { name, description, path: displayPath(root, path) }
}

function requiredString(metadata: Record<string, unknown>, key: string, root: string, path: string): string {
  const value = metadata[key]
  if (typeof value !== 'string' || value.trim() === '') {
    throw new Error(`${displayPath(root, path)}: ${key} must be a non-empty string`)
  }
  return value.trim()
}

function displayPath(root: string, path: string): string {
  return join('playbooks', relative(root, path)).split(sep).join('/')
}
