import { expect, test } from 'bun:test'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'

test('Git askpass uses the renewed internal context and returns only the requested credential', async () => {
  const requests: { authorization: string | null; body: unknown }[] = []
  let consentRequired = false
  const server = Bun.serve({
    port: 0,
    async fetch(request) {
      requests.push({ authorization: request.headers.get('authorization'), body: await request.json() })
      if (consentRequired) {
        return Response.json(
          {
            error: {
              code: 'oauth_consent_required',
              authorization_url: 'https://pod.example/connectors?connection=work'
            }
          },
          { status: 403 }
        )
      }
      return Response.json({ username: 'x-access-token', password: 'ephemeral-installation-token' })
    }
  })
  const directory = await mkdtemp(join(tmpdir(), 'ankole-git-context-'))
  const context = join(directory, 'context.json')
  const invoke = async (prompt: string) => {
    const process = Bun.spawn([Bun.which('bun')!, resolve(import.meta.dir, '../scripts/git-askpass.ts'), prompt], {
      env: {
        PATH: globalThis.process.env.PATH!,
        ANKOLE_MCP_CONTEXT_FILE: context,
        ANKOLE_MCP_TOKEN: 'stale-token',
        ANKOLE_GITHUB_CONNECTION: 'work'
      },
      stdout: 'pipe',
      stderr: 'pipe'
    })
    return {
      status: await process.exited,
      stdout: await new Response(process.stdout).text(),
      stderr: await new Response(process.stderr).text()
    }
  }
  try {
    await writeFile(
      context,
      JSON.stringify({ token: 'renewed-turn-token', origin: `http://127.0.0.1:${server.port}` }),
      { mode: 0o600 }
    )
    expect(await invoke("Username for 'https://github.com/acme/app.git': ")).toEqual({
      status: 0,
      stdout: 'x-access-token\n',
      stderr: ''
    })
    expect(await invoke("Password for 'https://x-access-token@github.com/acme/app.git': ")).toEqual({
      status: 0,
      stdout: 'ephemeral-installation-token\n',
      stderr: ''
    })
    expect(requests).toEqual(
      Array.from({ length: 1 }, () => ({
        authorization: 'Bearer renewed-turn-token',
        body: { url: 'https://github.com/acme/app.git', connection: 'work' }
      }))
    )
    const unsupported = await invoke("Password for 'http://github.com/acme/app.git': ")
    expect(unsupported.status).not.toBe(0)
    expect(requests).toHaveLength(1)
    consentRequired = true
    const rejected = await invoke("Password for 'https://x-access-token@github.com/acme/app.git': ")
    expect(rejected.status).not.toBe(0)
    expect(rejected.stdout).toBe('')
    expect(rejected.stderr).toContain('oauth_consent_required')
    expect(rejected.stderr).toContain('https://pod.example/connectors?connection=work')
    expect(rejected.stderr).not.toContain('renewed-turn-token')
  } finally {
    server.stop(true)
    await rm(directory, { recursive: true, force: true })
  }
})
