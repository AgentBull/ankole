import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import type { ChildProcess } from 'node:child_process'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { browserClientContextFromEnv, sendBrowserCommand, type BrowserClientContext } from '../../src/client'
import { chromiumExecutable, integrationEnabled, startDaemon, waitForExit } from './harness'

describe.skipIf(!integrationEnabled)('browser combobox, diagnostics, media policy, and WebMCP features', () => {
  let root: string
  let socketPath: string
  let daemon: ChildProcess
  let context: BrowserClientContext

  beforeAll(async () => {
    root = await mkdtemp('/tmp/ankole-browser-features-')
    socketPath = join(root, 'socket', 'browser.sock')
    const materialPath = join(root, 'material.json')
    const material = {
      protocol_version: 1,
      route_id: 'br_feat1234567890ab',
      data_root: join(root, 'data'),
      artifact_root: join(root, 'artifacts'),
      immutable_fingerprint: 'sha256:features-integration',
      material_generation: 0,
      profile: { mode: 'persistent_user_data_dir' },
      backend: { kind: 'local_chromium', executable: chromiumExecutable, args: [] },
      navigation: { ssrf_filter: false, allow_file_urls: true },
      idle_ttl_ms: 60_000
    }
    await writeFile(materialPath, `${JSON.stringify(material)}\n`, { mode: 0o600 })
    daemon = await startDaemon(socketPath)
    context = await browserClientContextFromEnv({
      ANKOLE_BROWSER_SOCKET: socketPath,
      ANKOLE_BROWSER_ROUTE: material.route_id,
      ANKOLE_BROWSER_SESSION: 'default',
      ANKOLE_BROWSER_MATERIAL: materialPath,
      ANKOLE_BROWSER_TIMEOUT_MS: '10000'
    })
  }, 20_000)

  afterAll(async () => {
    if (context) {
      for (const session of ['combobox-batch', 'diagnostics-downloads', 'media-and-webmcp']) {
        await sendBrowserCommand({ ...context, session }, { name: 'close', args: {} }, { timeoutMs: 10_000 }).catch(
          () => undefined
        )
      }
      const purged = await sendBrowserCommand(
        context,
        { name: 'lifecycle', args: { verb: 'purge' } },
        { timeoutMs: 10_000 }
      )
      expect(purged.ok).toBe(true)
    }
    daemon?.kill('SIGTERM')
    if (daemon) await waitForExit(daemon, 5_000)
    await rm(root, { recursive: true, force: true })
  }, 20_000)

  test('select drives ARIA combobox portals and batch --snap-diff returns only newly revealed controls', async () => {
    const comboContext = { ...context, session: 'combobox-batch' }
    const comboFile = join(root, 'combobox-form.html')
    await writeFile(
      comboFile,
      `<!doctype html><meta charset="utf-8"><title>Combobox form</title>
      <label for="email">Work email</label>
      <input id="email" type="email" value="">
      <button id="plan-trigger" role="combobox" aria-haspopup="listbox" aria-expanded="false" aria-controls="plan-portal">
        Select plan
      </button>
      <div id="region-combo" role="combobox" aria-expanded="false" aria-controls="region-portal">
        <input id="region-input" placeholder="Filter region" autocomplete="off">
      </div>
      <button id="save-form">Save workspace</button>
      <div id="plan-portal" role="listbox" hidden>
        <div role="option" data-value="starter">Starter</div>
        <div role="option" data-value="enterprise">Enterprise</div>
      </div>
      <div id="unrelated-sidebar-listbox" role="listbox">
        <div role="option" data-value="wrong-control">ap-northeast-1</div>
      </div>
      <div id="region-portal" role="listbox" hidden></div>
      <div id="result-modal" role="dialog" aria-label="Workspace provisioned" hidden>
        <button id="copy-key">Copy API key</button>
      </div>
      <script>
        const planTrigger = document.getElementById('plan-trigger');
        const planPortal = document.getElementById('plan-portal');
        planTrigger.addEventListener('click', () => {
          const next = planTrigger.getAttribute('aria-expanded') !== 'true';
          planTrigger.setAttribute('aria-expanded', String(next));
          planPortal.hidden = !next;
        });
        planPortal.addEventListener('click', event => {
          const opt = event.target.closest('[role="option"]');
          if (!opt) return;
          planTrigger.textContent = opt.textContent.trim();
          planTrigger.dataset.selected = opt.dataset.value;
          planTrigger.setAttribute('aria-expanded', 'false');
          planPortal.hidden = true;
        });

        const allRegions = ['us-east-1', 'eu-central-1', 'ap-northeast-1'];
        const regionCombo = document.getElementById('region-combo');
        const regionInput = document.getElementById('region-input');
        const regionPortal = document.getElementById('region-portal');
        function renderRegions(filterText) {
          regionPortal.innerHTML = '';
          for (const item of allRegions.filter(r => r.includes(filterText.toLowerCase()))) {
            const div = document.createElement('div');
            div.setAttribute('role', 'option');
            div.textContent = item;
            div.addEventListener('click', () => {
              regionInput.value = item;
              regionCombo.dataset.selected = item;
              regionCombo.setAttribute('aria-expanded', 'false');
              regionPortal.hidden = true;
            });
            regionPortal.appendChild(div);
          }
        }
        document.getElementById('unrelated-sidebar-listbox').addEventListener('click', () => {
          window.__clickedUnrelatedListbox = true;
        });
        regionCombo.addEventListener('click', () => {
          regionCombo.setAttribute('aria-expanded', 'true');
          regionPortal.hidden = false;
          // Delay rendering options slightly so #region-portal starts empty while #unrelated-sidebar-listbox is already visible.
          setTimeout(() => renderRegions(regionInput.value), 60);
        });
        regionInput.addEventListener('input', () => {
          regionCombo.setAttribute('aria-expanded', 'true');
          regionPortal.hidden = false;
          regionPortal.innerHTML = '';
          setTimeout(() => renderRegions(regionInput.value), 60);
        });

        document.getElementById('save-form').addEventListener('click', () => {
          document.title = [
            document.getElementById('email').value,
            planTrigger.dataset.selected || '',
            regionCombo.dataset.selected || '',
            window.__clickedUnrelatedListbox ? 'LEAKED' : 'ISOLATED'
          ].join('|');
          document.getElementById('result-modal').hidden = false;
        });
      </script>`
    )

    expect((await sendBrowserCommand(comboContext, { name: 'open', args: { url: `file://${comboFile}` } })).ok).toBe(
      true
    )
    const initial = await sendBrowserCommand(comboContext, { name: 'snapshot', args: { interactive: true } })
    expect(initial.ok).toBe(true)
    const snapText = String(initial.ok ? initial.data : '')
    const emailRef = snapText.match(/textbox "Work email" \[ref=(e\d+)\]/)?.[1]
    const planRef = snapText.match(/combobox "Select plan" \[ref=(e\d+)\]/)?.[1]
    const saveRef = snapText.match(/button "Save workspace" \[ref=(e\d+)\]/)?.[1]
    expect(emailRef && planRef && saveRef).toBeTruthy()

    const batched = await sendBrowserCommand(comboContext, {
      name: 'batch',
      args: {
        bail: true,
        snap: 'diff',
        commands: [
          { name: 'fill', args: { selector: `@${emailRef}`, text: 'ops@example.com' } },
          { name: 'select', args: { selector: `@${planRef}`, value: 'Enterprise' } },
          { name: 'select', args: { selector: '#region-combo', value: 'ap-northeast-1' } },
          { name: 'click', args: { selector: `@${saveRef}` } }
        ]
      }
    })
    expect(batched.ok).toBe(true)
    if (!batched.ok) throw new Error(batched.error.message)
    const batchData = batched.data as {
      results: Array<{ ok: boolean }>
      snapshot: string
      snapshot_mode: string
    }
    expect(batchData.results).toHaveLength(4)
    expect(batchData.results.every(entry => entry.ok)).toBe(true)
    expect(batchData.snapshot_mode).toBe('diff')
    expect(batchData.snapshot).toContain('Copy API key')
    expect(batchData.snapshot).not.toContain('Save workspace')

    expect(await sendBrowserCommand(comboContext, { name: 'get', args: { property: 'title' } })).toMatchObject({
      ok: true,
      data: 'ops@example.com|enterprise|ap-northeast-1|ISOLATED'
    })
  }, 20_000)

  test('diagnostics redacts secrets, filters static noise, and archives downloads under artifact_root/downloads', async () => {
    const diagContext = { ...context, session: 'diagnostics-downloads' }
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      fetch(req) {
        const url = new URL(req.url)
        if (url.pathname === '/api/ok') {
          return new Response(JSON.stringify({ ok: true }), { headers: { 'content-type': 'application/json' } })
        }
        if (url.pathname === '/api/fail') {
          return new Response(JSON.stringify({ error: 'boom' }), {
            status: 502,
            headers: { 'content-type': 'application/json', 'set-cookie': 'sid=topsecret' }
          })
        }
        if (url.pathname === '/missing.png') {
          return new Response('not found', { status: 404, headers: { 'content-type': 'image/png' } })
        }
        if (url.pathname === '/export.csv') {
          return new Response('id,amount\n1,42\n', {
            headers: {
              'content-type': 'text/csv',
              'content-disposition': 'attachment; filename="report.csv"'
            }
          })
        }
        return new Response(
          `<!doctype html><title>Diagnostics page</title>
          <img src="/missing.png">
          <a id="dl" href="/export.csv?token=dl_secret_999">Download CSV</a>
          <script>
            console.log('benign info log');
            console.error('Auth failed for https://user:pw@127.0.0.1/callback?api_key=leak_123');
            fetch('/api/ok?page=1');
            fetch('/api/fail?api_key=sk_secret_777&tenant=acme');
            setTimeout(() => { throw new Error('Unhandled widget failure'); }, 20);
          </script>`,
          { headers: { 'content-type': 'text/html' } }
        )
      }
    })

    try {
      expect((await sendBrowserCommand(diagContext, { name: 'open', args: { url: server.url.href } })).ok).toBe(true)
      await Bun.sleep(150)

      const firstClick = await sendBrowserCommand(diagContext, { name: 'click', args: { selector: '#dl' } })
      expect(firstClick.ok).toBe(true)
      if (!firstClick.ok) throw new Error(firstClick.error.message)
      const firstDownloads = (firstClick.data as { downloads?: Array<{ filename: string; path: string; url: string }> })
        .downloads
      expect(firstDownloads).toHaveLength(1)
      expect(firstDownloads![0]!.filename).toBe('report.csv')
      expect(firstDownloads![0]!.url).toContain('token=[REDACTED]')
      expect(firstDownloads![0]!.url).not.toContain('dl_secret_999')
      expect(await readFile(firstDownloads![0]!.path, 'utf8')).toBe('id,amount\n1,42\n')

      // Trigger a second download with the same suggested filename to verify collision deduplication.
      const secondClick = await sendBrowserCommand(diagContext, { name: 'click', args: { selector: '#dl' } })
      expect(secondClick.ok).toBe(true)
      if (!secondClick.ok) throw new Error(secondClick.error.message)
      const secondDownloads = (secondClick.data as { downloads?: Array<{ filename: string; path: string }> }).downloads
      expect(secondDownloads?.[0]?.filename).toBe('report-2.csv')

      const diag = await sendBrowserCommand(diagContext, { name: 'diagnostics', args: { clear: true } })
      expect(diag.ok).toBe(true)
      if (!diag.ok) throw new Error(diag.error.message)
      const serialized = JSON.stringify(diag.data)
      expect(serialized).not.toContain('sk_secret_777')
      expect(serialized).not.toContain('leak_123')
      expect(serialized).not.toContain('dl_secret_999')
      expect(serialized).not.toContain('topsecret')
      expect(serialized).not.toContain('benign info log')
      expect(serialized).not.toContain('/missing.png')
      expect(serialized).not.toContain('/api/ok')
      expect(serialized).toContain('Unhandled widget failure')
      expect(serialized).toContain('/api/fail?api_key=[REDACTED]&tenant=acme')
      expect(serialized).toContain('report.csv')
      expect(serialized).toContain('report-2.csv')

      const afterClear = await sendBrowserCommand(diagContext, { name: 'diagnostics', args: {} })
      expect(afterClear).toMatchObject({
        ok: true,
        data: { mode: 'errors', console: [], network: [], downloads: [] }
      })
    } finally {
      server.stop(true)
    }
  }, 20_000)

  test('rendered fetch blocks media by default, network toggles interactive no-media, and webmcp invokes page tools', async () => {
    const featureContext = { ...context, session: 'media-and-webmcp' }
    let imageHits = 0
    let fontHits = 0
    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      fetch(req) {
        const url = new URL(req.url)
        if (url.pathname === '/hero.png') {
          imageHits += 1
          return new Response('fake-png', { headers: { 'content-type': 'image/png' } })
        }
        if (url.pathname === '/brand.woff2') {
          fontHits += 1
          return new Response('fake-font', { headers: { 'content-type': 'font/woff2' } })
        }
        return new Response(
          `<!doctype html><meta charset="utf-8"><title>Media and WebMCP</title>
          <style>@font-face { font-family: 'Brand'; src: url('/brand.woff2') format('woff2'); } body { font-family: 'Brand', sans-serif; }</style>
          <img src="/hero.png" alt="Hero">
          <main>Fast extracted article body</main>
          <form toolname="create_ticket" tooldescription="Create a support ticket" toolautosubmit>
            <input name="subject" required toolparamdescription="Ticket subject">
            <select name="priority"><option value="normal">Normal</option><option value="urgent">Urgent</option></select>
          </form>
          <div id="ticket-banner" hidden><button id="ack-ticket">Acknowledge ticket</button></div>
          <script>
            document.querySelector('form[toolname="create_ticket"]').addEventListener('submit', event => {
              event.preventDefault();
              const data = new FormData(event.target);
              document.title = data.get('subject') + ':' + data.get('priority');
              document.getElementById('ticket-banner').hidden = false;
            });
          </script>`,
          { headers: { 'content-type': 'text/html' } }
        )
      }
    })

    try {
      // 1. Rendered fallback (`fetch`) aborts image/font requests automatically on temporary extraction pages.
      const fetched = await sendBrowserCommand(featureContext, {
        name: 'fetch',
        args: { urls: [server.url.href] }
      })
      expect(fetched).toMatchObject({
        ok: true,
        data: {
          success: true,
          results: [{ title: 'Media and WebMCP', text: expect.stringContaining('Fast extracted article body') }]
        }
      })
      expect(imageHits).toBe(0)
      expect(fontHits).toBe(0)

      // 2. Interactive `network no-media` blocks images during `open`, and `network default` restores loading.
      expect(await sendBrowserCommand(featureContext, { name: 'network', args: { mode: 'no-media' } })).toMatchObject({
        ok: true,
        data: { mode: 'no-media', blocked_resource_types: ['image', 'media', 'font'] }
      })
      expect((await sendBrowserCommand(featureContext, { name: 'open', args: { url: server.url.href } })).ok).toBe(true)
      await Bun.sleep(100)
      expect(imageHits).toBe(0)

      expect(await sendBrowserCommand(featureContext, { name: 'network', args: { mode: 'default' } })).toMatchObject({
        ok: true,
        data: { mode: 'default', blocked_resource_types: [] }
      })
      expect((await sendBrowserCommand(featureContext, { name: 'open', args: { url: server.url.href } })).ok).toBe(true)
      await Bun.sleep(150)
      expect(imageHits).toBeGreaterThan(0)

      // 3. Baseline snapshot + declarative WebMCP discovery and invocation with `--snap-diff`.
      expect((await sendBrowserCommand(featureContext, { name: 'snapshot', args: { interactive: true } })).ok).toBe(
        true
      )
      const listedDeclarative = await sendBrowserCommand(featureContext, { name: 'webmcp', args: { action: 'list' } })
      expect(listedDeclarative).toMatchObject({
        ok: true,
        data: {
          supported: true,
          protocol: 'declarative_dom',
          tools: [
            {
              name: 'create_ticket',
              description: 'Create a support ticket',
              annotations: { autosubmit: true }
            }
          ]
        }
      })

      const calledDeclarative = await sendBrowserCommand(featureContext, {
        name: 'webmcp',
        args: {
          action: 'call',
          tool: 'create_ticket',
          input: { subject: 'Outage', priority: 'urgent' },
          snap: 'diff'
        }
      })
      expect(calledDeclarative).toMatchObject({
        ok: true,
        data: {
          protocol: 'declarative_dom',
          tool: 'create_ticket',
          output: { filled: ['subject', 'priority'], autosubmitted: true },
          refs_may_be_stale: false,
          snapshot_mode: 'diff',
          snapshot: expect.stringContaining('Acknowledge ticket')
        }
      })
      expect(await sendBrowserCommand(featureContext, { name: 'get', args: { property: 'title' } })).toMatchObject({
        ok: true,
        data: 'Outage:urgent'
      })

      // 4. Imperative `navigator.modelContext` takes precedence when registered by the page.
      expect(
        (
          await sendBrowserCommand(featureContext, {
            name: 'eval',
            args: {
              expression: `navigator.modelContext = {
                async getTools() { return [{ name: 'sum_items', description: 'Sum numbers', inputSchema: { type: 'object' } }] },
                async executeTool(tool, input) { return JSON.stringify({ tool: tool.name, total: (input.values || []).reduce((a, b) => a + b, 0) }) }
              }; true`
            }
          })
        ).ok
      ).toBe(true)

      const listedImperative = await sendBrowserCommand(featureContext, { name: 'webmcp', args: { action: 'list' } })
      expect(listedImperative).toMatchObject({
        ok: true,
        data: { supported: true, protocol: 'model_context', tools: [{ name: 'sum_items' }] }
      })
      const calledImperative = await sendBrowserCommand(featureContext, {
        name: 'webmcp',
        args: { action: 'call', tool: 'sum_items', input: { values: [10, 15, 17] } }
      })
      expect(calledImperative).toMatchObject({
        ok: true,
        data: {
          protocol: 'model_context',
          tool: 'sum_items',
          output: { tool: 'sum_items', total: 42 },
          refs_may_be_stale: true
        }
      })
    } finally {
      server.stop(true)
    }
  }, 25_000)
})
