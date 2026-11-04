import { expect, test } from 'bun:test'
import { basename, dirname, join } from 'node:path'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { mkdirAgentSync } from '../../../src/common/agent-user'
import { createContainerComputer } from '../../../src/tools/computer/computer'
import { jobWebFetchResult } from '../../../src/tools/web/web-fetch-result'
import type { JsonObject } from '@agentbull/active-support'

if (process.platform !== 'linux' || !existsSync('/etc/ankole-agent-computer-container')) {
  throw new Error('Web fetch permission tests require the Worker image; run bun run test:integration:docker')
}

for (const link of ['file', 'directory']) {
  test(`Job page writes cannot use an Agent-controlled ${link} link to overwrite a root document`, async () => {
    expect(process.getuid!()).toBe(0)
    const root = mkdtempSync(join(tmpdir(), 'web-fetch-permissions-'))
    chmodSync(root, 0o755)
    const workspace = join(root, 'workspace')
    mkdirAgentSync(workspace, 0o700)
    const protectedDirectory = join(root, 'protected')
    mkdirSync(protectedDirectory, { mode: 0o700 })
    const computer = createContainerComputer(workspace, workspace)
    const text = 'article line\n'.repeat(5000)
    const page = {
      url: 'https://example.com/article',
      text,
      total_characters: text.length,
      stored_characters: text.length
    }
    try {
      const first = await jobWebFetchResult([page], workspace, computer)
      const file = String((first.details.results as JsonObject[])[0]!.file_path)
      expect(readFileSync(file, 'utf8')).toBe(text)
      expect(statSync(file).uid).toBe(1000)
      const target = join(protectedDirectory, basename(file))
      writeFileSync(target, 'root document', { mode: 0o600 })
      const replace = await computer.runCommand({
        cmd: process.execPath,
        args: [
          '-e',
          `
import { rm, symlink } from 'node:fs/promises'
await rm(process.argv[1], { recursive: true, force: true })
await symlink(process.argv[2], process.argv[1])
`,
          link === 'file' ? file : dirname(file),
          link === 'file' ? target : protectedDirectory
        ]
      })
      expect(replace.exitCode, await replace.output()).toBe(0)
      const result = await jobWebFetchResult([page], workspace, computer)
      const saved = (result.details.results as JsonObject[])[0]!
      expect(saved).toMatchObject({ file_unavailable: true })
      expect(saved).not.toHaveProperty('file_path')
      expect(readFileSync(target, 'utf8')).toBe('root document')
      expect(result.content[0]).toMatchObject({ text: expect.stringContaining('Full page file unavailable') })
    } finally {
      rmSync(root, { recursive: true, force: true })
    }
  })
}
