import { copyFile, mkdir, rm } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { browserClientContextFromEnv, sendBrowserCommand, type BrowserCommand } from '@ankole/browser'
import { isRecord } from '@agentbull/active-support'

export type AppletInspectOptions = { screenshot?: string; waitMs: number }

/** Render a diagnostic ticket in a disposable browser profile with no interactive-session cookies. */
export async function inspectApplet(ticket: unknown, options: AppletInspectOptions) {
  if (!isRecord(ticket) || typeof ticket.url !== 'string') {
    throw new Error('Applet inspection requires a diagnostic URL')
  }
  const current = await browserClientContextFromEnv()
  const executable =
    current.material.backend.kind === 'local_chromium'
      ? current.material.backend.executable
      : process.env.ANKOLE_BROWSER_CHROMIUM_EXECUTABLE
  if (!executable) throw new Error('Applet inspection requires the Worker local Chromium executable')
  const route = `br_${crypto.randomUUID().replaceAll('-', '')}`
  const artifactRoot = join(current.artifactRoot, 'applet-inspect', route)
  const context = {
    ...current,
    route,
    session: 'default',
    artifactRoot,
    material: {
      ...current.material,
      route_id: route,
      data_root: join(dirname(current.material.data_root), route),
      artifact_root: artifactRoot,
      immutable_fingerprint: route,
      material_generation: 0,
      profile: { mode: 'persistent_user_data_dir' as const },
      backend: { kind: 'local_chromium' as const, executable, args: [] },
      // The ticket's control-plane origin can be on the Worker's private network.
      navigation: { ssrf_filter: false, allow_file_urls: false },
      idle_ttl_ms: 60_000
    }
  }
  await mkdir(artifactRoot, { recursive: true })
  const send = async (command: BrowserCommand, timeoutMs = 30_000) => {
    const response = await sendBrowserCommand(context, command, { timeoutMs })
    if (!response.ok) throw new Error(`${response.error.code}: ${response.error.message}`)
    return response.data
  }
  const runtimeErrors: unknown[] = []
  try {
    try {
      await send({ name: 'open', args: { url: ticket.url } })
      await send(
        {
          name: 'wait',
          args: {
            expression:
              'Boolean(window.__ANKOLE_APPLET_DIAGNOSTIC__?.settled || window.__ANKOLE_APPLET_DIAGNOSTIC__?.mounted || window.__ANKOLE_APPLET_DIAGNOSTIC__?.runtimeErrors?.length)'
          }
        },
        15_000
      )
    } catch (error) {
      runtimeErrors.push(error instanceof Error ? error.message : String(error))
    }
    if (options.waitMs > 0) await send({ name: 'wait', args: { ms: options.waitMs } })
    const snapshot = await send({
      name: 'eval',
      args: {
        expression: `(() => {
      const state = window.__ANKOLE_APPLET_DIAGNOSTIC__;
      const frame = document.querySelector('iframe');
      return { mounted: state?.mounted === true, runtimeErrors: state?.runtimeErrors ?? [],
        text: (frame?.contentDocument?.body?.innerText ?? document.body.innerText).slice(0, 12000) };
    })()`
      }
    })
    const diagnostics = await send({ name: 'diagnostics', args: { include_static: true } })
    const consoleEntries = isRecord(diagnostics) && Array.isArray(diagnostics.console) ? diagnostics.console : []
    const networkEntries = isRecord(diagnostics) && Array.isArray(diagnostics.network) ? diagnostics.network : []
    let screenshot: unknown
    if (options.screenshot) {
      const capturedScreenshot = await send({ name: 'screenshot', args: { path: 'snapshot.png', full: true } })
      await mkdir(dirname(options.screenshot), { recursive: true })
      await copyFile(join(artifactRoot, 'snapshot.png'), options.screenshot)
      screenshot = { ...(isRecord(capturedScreenshot) ? capturedScreenshot : {}), path: options.screenshot }
    }
    const captured = isRecord(snapshot) ? snapshot : {}
    return {
      mounted: captured.mounted === true,
      runtimeErrors: [
        ...runtimeErrors,
        ...(Array.isArray(captured.runtimeErrors) ? captured.runtimeErrors : []),
        ...consoleEntries.filter(entry => isRecord(entry) && entry.type === 'pageerror')
      ],
      consoleErrors: consoleEntries.filter(
        entry => isRecord(entry) && ['error', 'assert'].includes(String(entry.type))
      ),
      failedRequests: networkEntries,
      text: typeof captured.text === 'string' ? captured.text : '',
      ...(screenshot === undefined ? {} : { screenshot })
    }
  } finally {
    await send({ name: 'lifecycle', args: { verb: 'purge' } }, 5_000).catch(() => undefined)
    await rm(context.material.data_root, { recursive: true, force: true }).catch(() => {})
    await rm(artifactRoot, { recursive: true, force: true }).catch(() => {})
  }
}
