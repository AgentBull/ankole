import { afterAll, beforeAll, describe, expect, test } from 'bun:test'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const script = join(import.meta.dir, '../../library/skills/ocr/scripts/ocr_api.py')

// The Skill's API script against a stand-in for the AIGateway `/ocr` endpoint.
describe('OCR Skill API script', () => {
  let dir: string
  let server: ReturnType<typeof Bun.serve>
  const requests: { authorization: string | null; path: string; body: Record<string, unknown> }[] = []

  beforeAll(() => {
    dir = mkdtempSync(join(tmpdir(), 'ankole-ocr-api-'))
    writeFileSync(join(dir, 'token'), 'agent-key\n')
    writeFileSync(join(dir, 'scan.pdf'), '%PDF-1.7 scanned')
    writeFileSync(join(dir, 'photo.png'), 'png bytes')
    server = Bun.serve({
      port: 0,
      async fetch(request) {
        const body = (await request.json()) as Record<string, unknown>
        requests.push({
          authorization: request.headers.get('authorization'),
          path: new URL(request.url).pathname,
          body
        })
        const document = body.document as { content_type: string }
        if (document.content_type === 'image/png') {
          return Response.json(
            { error: { param: 'document', code: 'unsupported_value', message: 'Configure an OCR model.' } },
            { status: 400 }
          )
        }
        return Response.json({
          model: 'mistral-main/mistral-ocr-latest',
          pages: [
            { index: 1, markdown: '# Invoice' },
            { index: 5, markdown: '' }
          ],
          usage: { pages: 2 }
        })
      }
    })
  })

  afterAll(() => {
    server.stop(true)
    rmSync(dir, { recursive: true, force: true })
  })

  // The stand-in endpoint answers from this process, so the script runs
  // without blocking the event loop.
  const run = async (...args: string[]) => {
    const child = Bun.spawn(['python3', script, ...args], {
      stdout: 'pipe',
      stderr: 'pipe',
      env: {
        ...process.env,
        ANKOLE_RUNTIME_AI_GATEWAY_URL: `http://127.0.0.1:${server.port}/api/v1/ai-gateway/`,
        ANKOLE_RUNTIME_AI_GATEWAY_TOKEN_FILE: join(dir, 'token')
      }
    })
    const [stdout, stderr, status] = await Promise.all([
      new Response(child.stdout).text(),
      new Response(child.stderr).text(),
      child.exited
    ])
    return { stdout, stderr, status }
  }

  test('sends a PDF with zero-based pages and prints each page under its one-based number', async () => {
    const result = await run(join(dir, 'scan.pdf'), '--pages', '2,6')

    expect(result.status, result.stderr).toBe(0)
    expect(result.stdout).toBe('--- page 2 ---\n# Invoice\n--- page 6 ---\n(no text detected)\n')
    expect(requests.at(-1)).toEqual({
      authorization: 'Bearer agent-key',
      path: '/api/v1/ai-gateway/ocr',
      body: {
        model: 'ocr.default',
        document: {
          content_type: 'application/pdf',
          base64: Buffer.from('%PDF-1.7 scanned').toString('base64')
        },
        pages: [1, 5]
      }
    })
  })

  test('--json prints the endpoint response', async () => {
    const result = await run(join(dir, 'scan.pdf'), '--json')

    expect(result.status, result.stderr).toBe(0)
    expect(JSON.parse(result.stdout).usage).toEqual({ pages: 2 })
    expect(requests.at(-1)?.body.pages).toBeUndefined()
  })

  test('prints the endpoint error and exits 1 when the request is rejected', async () => {
    const result = await run(join(dir, 'photo.png'))

    expect(result.status).toBe(1)
    expect(result.stderr).toContain('HTTP 400')
    expect(result.stderr).toContain('Configure an OCR model.')
  })

  test('refuses a file type that the endpoint does not read', async () => {
    writeFileSync(join(dir, 'notes.txt'), 'text')
    const result = await run(join(dir, 'notes.txt'))

    expect(result.status).toBe(2)
    expect(result.stderr).toContain('unsupported input type')
  })
})
