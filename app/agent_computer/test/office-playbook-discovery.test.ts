import { describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

const packageRoot = join(import.meta.dir, '..', '..', 'library', 'agent-plugins', 'office')
const scriptPath = join(packageRoot, 'tools', 'list_playbooks.ts')

describe('@ankole/agent-computer office Playbook discovery', () => {
  it('keeps each other product on its own Playbooks', async () => {
    const pptx = await runDiscovery('pptx')
    const docx = await runDiscovery('docx')

    expect(pptx.stdout).not.toContain('financial-model')
    expect(docx.stdout).toContain('- academic-paper (')
    expect(docx.stdout).not.toContain('business-proposal')
  })

  it('rejects a missing or unknown product', async () => {
    const missing = await runDiscovery()
    const unknown = await runDiscovery('ppt')

    for (const result of [missing, unknown]) {
      expect(result.exitCode).toBe(2)
      expect(result.stderr).toContain('usage: bun list_playbooks.ts <docx|pptx|xlsx> [playbooks-root]')
    }
  })

  it('reports a Playbook that applies to no known product', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-office-playbooks-'))
    const path = join(root, 'invalid.md')
    writeFileSync(path, '---\nname: invalid\ndescription: "Use when testing."\nproducts: [word]\n---\n\n# Invalid\n')

    try {
      const result = await runDiscovery('docx', root)
      expect(result.exitCode).not.toBe(0)
      expect(result.stderr).toContain(`${resolve(path)}: unknown product word`)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('reports a Playbook that omits its products', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-office-playbooks-'))
    const path = join(root, 'invalid.md')
    writeFileSync(path, '---\nname: invalid\ndescription: "Use when testing."\n---\n\n# Invalid\n')

    try {
      const result = await runDiscovery('docx', root)
      expect(result.exitCode).not.toBe(0)
      expect(result.stderr).toContain(`${resolve(path)}: products must list at least one of docx, pptx, xlsx`)
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
})

async function runDiscovery(product?: string, root?: string) {
  const args = [product, root].filter((value): value is string => value !== undefined)
  const process = Bun.spawn(['bun', scriptPath, ...args], { stdout: 'pipe', stderr: 'pipe' })
  const [exitCode, stdout, stderr] = await Promise.all([
    process.exited,
    new Response(process.stdout).text(),
    new Response(process.stderr).text()
  ])
  return { exitCode, stdout, stderr }
}
