import { afterEach, describe, expect, it } from 'bun:test'
import { chmodSync, mkdtempSync, readFileSync, rmSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { LARK_TENANT_TOKEN_FILE_ENV } from '../src/core/turns/lark-credential'

const sourceWrapper = join(import.meta.dir, '../scripts/lark-cli.sh')
const roots: string[] = []

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true })
})

describe('lark-cli image wrapper', () => {
  it('loads the current token file for each command', () => {
    const fixture = wrapperFixture()
    writeFileSync(fixture.token, 'tenant-token-1\n', { mode: 0o600 })

    expect(runWrapper(fixture, ['doc', 'get']).stdout?.toString()).toContain('tenant-token-1|doc get')
    writeFileSync(fixture.token, 'tenant-token-2\n', { mode: 0o600 })
    expect(runWrapper(fixture, ['doc', 'get']).stdout?.toString()).toContain('tenant-token-2|doc get')
  })

  it('fails with an authentication error instead of using a stale token', () => {
    const fixture = wrapperFixture()
    writeFileSync(fixture.token, 'stale-token\n', { mode: 0o600 })
    const stale = new Date(Date.now() - 301_000)
    utimesSync(fixture.token, stale, stale)

    const result = runWrapper(fixture, ['doc', 'get'])
    expect(result.exitCode).toBe(3)
    expect(result.stderr?.toString()).toContain('"subtype":"credential_unavailable"')
    expect(result.stdout?.toString()).toBe('')
  })

  it('keeps unauthenticated CLI commands usable when no runtime file is configured', () => {
    const fixture = wrapperFixture()
    const result = runWrapper(fixture, ['--version'], false)

    expect(result.exitCode).toBe(0)
    expect(result.stdout?.toString()).toContain('|--version')
  })
})

function wrapperFixture(): { root: string; wrapper: string; realCLI: string; token: string } {
  const root = mkdtempSync(join(tmpdir(), 'ankole-lark-cli-wrapper-'))
  roots.push(root)
  const wrapper = join(root, 'lark-cli')
  const realCLI = join(root, 'lark-cli-real')
  const token = join(root, 'tenant-token')
  const source = readFileSync(sourceWrapper, 'utf8').replace(
    'readonly real_cli=/usr/local/libexec/lark-cli',
    `readonly real_cli=${realCLI}`
  )

  writeFileSync(wrapper, source)
  writeFileSync(realCLI, '#!/bin/sh\nprintf \'%s|%s\\n\' "${LARKSUITE_CLI_TENANT_ACCESS_TOKEN:-}" "$*"\n')
  chmodSync(wrapper, 0o755)
  chmodSync(realCLI, 0o755)
  return { root, wrapper, realCLI, token }
}

function runWrapper(
  fixture: { wrapper: string; token: string },
  args: string[],
  withCredential = true
): ReturnType<typeof Bun.spawnSync> {
  const env: Record<string, string | undefined> = {
    ...process.env,
    LARKSUITE_CLI_TENANT_ACCESS_TOKEN: 'frozen-token'
  }
  if (withCredential) env[LARK_TENANT_TOKEN_FILE_ENV] = fixture.token
  else delete env[LARK_TENANT_TOKEN_FILE_ENV]
  return Bun.spawnSync([fixture.wrapper, ...args], { env, stdout: 'pipe', stderr: 'pipe' })
}
