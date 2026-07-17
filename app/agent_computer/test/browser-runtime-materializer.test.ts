import { afterEach, describe, expect, test } from 'bun:test'
import { mkdtemp, mkdir, readFile, realpath, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { BrowserRouteMaterializer, withoutBrowserMaterialSourceEnv } from '../src/browser-runtime/materializer'
import { browserSandboxRuntime } from '../src/browser-runtime/sandbox-runtime'

const roots: string[] = []

afterEach(async () => {
  await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true })))
})

describe('rendered web_fetch fallback materialization', () => {
  test('keeps the rendered fetch idle TTL out of persistent Codex browser routes', async () => {
    const root = await temporaryRoot()
    const materializer = new BrowserRouteMaterializer({
      root: join(root, 'runtime'),
      localChromiumExecutable: '/bin/true'
    })
    const renderedSettings = { ssrfFilter: true, idleTtlMs: 5 * 60 * 1_000 }

    const ephemeral = await materializer.materializeEphemeral({ settings: renderedSettings })
    const persistent = await materializer.materializePersistent({
      scopeRoot: join(root, 'job'),
      artifactRoot: join(root, 'job', 'browser'),
      settings: renderedSettings
    })

    expect(ephemeral.material.idle_ttl_ms).toBe(5 * 60 * 1_000)
    expect(persistent.material.idle_ttl_ms).toBe(30 * 60 * 1_000)
    await Promise.all([ephemeral.cleanup(), persistent.cleanup()])
  })

  test('creates a new ephemeral route for every fetch', async () => {
    const root = await temporaryRoot()
    const materializer = new BrowserRouteMaterializer({
      root: join(root, 'runtime'),
      socketPath: join(root, 'socket', 'browser.sock'),
      localChromiumExecutable: '/bin/true'
    })
    const settings = {
      ssrfFilter: false,
      workerEnv: {
        BROWSER_BACKEND_JSON: JSON.stringify({
          kind: 'local_chromium',
          executable: '/bin/true',
          args: ['--fallback-only']
        })
      }
    }

    const first = await materializer.materializeEphemeral({ settings })
    const second = await materializer.materializeEphemeral({ settings })

    expect(first.route).not.toBe(second.route)
    expect(first.material.material_generation).toBe(0)
    expect(first.material.navigation.ssrf_filter).toBe(false)
    expect(first.material.backend).toMatchObject({ args: ['--fallback-only'] })
    expect(first.artifactRoot).toContain('ephemeral-artifacts')
    expect(first.materialPath).not.toContain('/workspace/')
    await Promise.all([first.cleanup(), second.cleanup()])
  })

  test('does not forward renderer source configuration into model-visible worker env', async () => {
    const root = await temporaryRoot()
    const seed = join(root, 'seed')
    await mkdir(seed, { recursive: true })
    await writeFile(join(seed, 'Preferences'), 'one')
    const materializer = new BrowserRouteMaterializer({
      root: join(root, 'runtime'),
      localChromiumExecutable: '/bin/true'
    })
    const runtime = await materializer.materializeEphemeral({
      settings: { ssrfFilter: true, workerEnv: { BROWSER_PROFILE_SEED_PATH: seed } }
    })

    expect(runtime.material.profile.seed_path).toBe(await realpath(seed))
    expect(
      withoutBrowserMaterialSourceEnv({
        SAFE_VALUE: 'kept',
        BROWSER_BACKEND_JSON: 'renderer backend',
        BROWSER_PROFILE_SEED_PATH: seed,
        BROWSER_PROFILE_SEED_FINGERPRINT: 'renderer fingerprint'
      })
    ).toEqual({ SAFE_VALUE: 'kept' })
    await runtime.cleanup()
  })
})

describe('persistent Codex browser materialization', () => {
  test('keeps one opaque route and increments generation when final material refreshes', async () => {
    const root = await temporaryRoot()
    const scopeRoot = join(root, 'job')
    const materializer = new BrowserRouteMaterializer({
      root: join(root, 'runtime'),
      socketPath: join(root, 'socket', 'browser.sock'),
      localChromiumExecutable: '/bin/true'
    })
    const first = await materializer.materializePersistent({
      scopeRoot,
      artifactRoot: join(scopeRoot, 'browser'),
      settings: {
        ssrfFilter: true,
        workerEnv: {
          BROWSER_BACKEND_JSON: JSON.stringify({
            kind: 'local_chromium',
            executable: '/bin/true',
            args: ['--generation=one']
          })
        }
      }
    })
    const second = await materializer.materializePersistent({
      scopeRoot,
      artifactRoot: join(scopeRoot, 'browser'),
      settings: {
        ssrfFilter: true,
        workerEnv: {
          BROWSER_BACKEND_JSON: JSON.stringify({
            kind: 'local_chromium',
            executable: '/bin/true',
            args: ['--generation=two']
          })
        }
      }
    })

    expect(second.route).toBe(first.route)
    expect(second.material.material_generation).toBe(first.material.material_generation + 1)
    const routeRecord = JSON.parse(await readFile(join(scopeRoot, '.ankole', 'browser-route.json'), 'utf8'))
    expect(Object.keys(routeRecord).sort()).toEqual([
      'immutable_key',
      'material_generation',
      'material_hash',
      'route_id',
      'version'
    ])
    expect(JSON.stringify(routeRecord)).not.toContain('--generation=two')
    await Promise.all([first.cleanup(), second.cleanup()])
  })

  test('rotates the opaque route when profile seed identity changes', async () => {
    const root = await temporaryRoot()
    const scopeRoot = join(root, 'job')
    const seed = join(root, 'seed')
    await mkdir(seed, { recursive: true })
    await writeFile(join(seed, 'Preferences'), 'seed')
    const materializer = new BrowserRouteMaterializer({ root: join(root, 'runtime') })
    const first = await materializer.materializePersistent({
      scopeRoot,
      artifactRoot: join(scopeRoot, 'browser'),
      settings: {
        ssrfFilter: true,
        workerEnv: {
          BROWSER_PROFILE_SEED_PATH: seed,
          BROWSER_PROFILE_SEED_FINGERPRINT: 'sha256:first'
        }
      }
    })
    const second = await materializer.materializePersistent({
      scopeRoot,
      artifactRoot: join(scopeRoot, 'browser'),
      settings: {
        ssrfFilter: true,
        workerEnv: {
          BROWSER_PROFILE_SEED_PATH: seed,
          BROWSER_PROFILE_SEED_FINGERPRINT: 'sha256:second'
        }
      }
    })

    expect(second.route).not.toBe(first.route)
    expect(second.material.material_generation).toBe(0)
    await Promise.all([first.cleanup(), second.cleanup()])
  })

  test('projects only final reserved env and explicit read-only binds', async () => {
    const root = await temporaryRoot()
    const scopeRoot = join(root, 'job')
    const runtime = await new BrowserRouteMaterializer({
      root: join(root, 'runtime'),
      socketPath: join(root, 'socket', 'browser.sock'),
      nodePath: '/opt/ankole-browser/node/bin/node',
      runnerPath: '/opt/ankole-browser/dist/runner/bootstrap.js',
      localChromiumExecutable: '/bin/true'
    }).materializePersistent({
      scopeRoot,
      artifactRoot: join(scopeRoot, 'browser'),
      settings: { ssrfFilter: true }
    })
    const sandbox = browserSandboxRuntime(runtime)

    expect(sandbox.env).toMatchObject({
      ANKOLE_BROWSER_ROUTE: runtime.route,
      ANKOLE_BROWSER_SOCKET: '/run/ankole-browser/socket/browser.sock',
      ANKOLE_BROWSER_MATERIAL: '/run/ankole-browser/material/session.json',
      ANKOLE_BROWSER_ARTIFACT_ROOT: '/workspace/browser'
    })
    expect(sandbox.env.BROWSER_BACKEND_JSON).toBeUndefined()
    expect(sandbox.binds).toEqual([
      {
        source: join(root, 'socket'),
        target: '/run/ankole-browser/socket',
        readonly: true
      },
      {
        source: runtime.materialPath,
        target: '/run/ankole-browser/material/session.json',
        readonly: true
      }
    ])
    await runtime.cleanup()
  })
})

async function temporaryRoot(): Promise<string> {
  const root = await mkdtemp('/tmp/ankole-rendered-fetch-materializer-')
  roots.push(root)
  return root
}
