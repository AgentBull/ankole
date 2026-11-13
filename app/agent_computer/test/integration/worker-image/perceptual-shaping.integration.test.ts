import { describe, expect, it } from 'bun:test'
import { chmodSync, existsSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { commandEnv } from '../../../src/core/execution/command-env'

if (process.platform !== 'linux' || !existsSync('/etc/ankole-agent-computer-container')) {
  throw new Error(
    'Worker perceptual shaping image tests require the Worker image. Run `bun run test:integration:docker`.'
  )
}

describe('Worker image CLI perceptual shims', () => {
  it('shapes direct shell commands and automatically passes through pipelines via ANKOLE_HARNESS_STDOUT_ID', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'ankole-image-shim-'))
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      fetch() {
        return Response.json({
          total: 90,
          items: Array.from({ length: 90 }, (_, idx) => ({
            id: `item_${idx}`,
            label: `Repeated payload row ${idx} for perceptual shaping verification`,
            optional_flag: idx === 77 ? true : undefined
          }))
        })
      }
    })

    try {
      const env = commandEnv(undefined, { agentHome: dir })
      const url = `http://127.0.0.1:${server.port}/items`

      // 1. Bare curl in login bash (like CodexRunner shell execution) is shaped into unified schema.
      const bare = Bun.spawnSync(['bash', '-lc', `curl -fsSL ${url}`], { env })
      expect(bare.exitCode).toBe(0)
      const bareText = bare.stdout.toString('utf8')
      expect(bareText).toContain('JSON Object unified schema:')
      expect(bareText).toContain('"optional_flag"?: boolean')

      // 2. Piped curl (`curl ... | jq -r .items[77].id`) bypasses the shim via /proc/self/fd/1 mismatch!
      const piped = Bun.spawnSync(['bash', '-lc', `curl -fsSL ${url} | jq -r '.items[77].id'`], { env })
      expect(piped.exitCode).toBe(0)
      expect(piped.stdout.toString('utf8').trim()).toBe('item_77')

      // 3. Python subprocess capturing `curl` output also bypasses the shim automatically!
      const pyScript = join(dir, 'fetch_via_subproc.py')
      writeFileSync(
        pyScript,
        `import json, subprocess\nout = subprocess.check_output(["curl", "-fsSL", "${url}"], text=True)\nprint(json.loads(out)["items"][5]["id"])\n`
      )
      chmodSync(pyScript, 0o755)
      const subproc = Bun.spawnSync(['bash', '-lc', `python3 ${pyScript}`], { env })
      expect(subproc.exitCode).toBe(0)
      expect(subproc.stdout.toString('utf8').trim()).toBe('item_5')
    } finally {
      server.stop(true)
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it('passes through to the real command when a caller directory precedes the shim directory in PATH', () => {
    const env = commandEnv(undefined, { agentHome: tmpdir() })
    // Codex prepends its own directory, so the shim directory is not the first PATH entry.
    const run = Bun.spawnSync(['timeout', '5', 'cat', '/etc/hostname'], {
      env: { ...env, ANKOLE_RAW: '1', PATH: `/tmp/ankole-caller-bin:${env.PATH}` }
    })
    expect(run.exitCode).toBe(0)
    expect(run.stdout.toString('utf8').trim().length).toBeGreaterThan(0)
  })
})
