import { describe, expect, it } from 'bun:test'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { type WebhookRPCMethod, type WebhookRPCRequester } from '../src/lanes/rpc_lane'
import { startWebhookCLIBridge } from '../src/cli/webhooks/webhook-cli-bridge'
import { requestWebhookCLI } from '../src/cli/webhooks/webhook-cli-client'
import { WEBHOOK_CLI_HELP, commandFromArgs, helpRequested } from '../src/cli/webhooks/webhook-cli'

describe('webhook CLI', () => {
  it('parses the three small shell commands and rejects invalid options', () => {
    expect(
      commandFromArgs([
        'create',
        '--label',
        'Watch GitHub issues',
        '--mode',
        'standing',
        '--expires-at',
        '2026-08-01T00:00:00Z'
      ])
    ).toEqual({
      operation: 'create',
      label: 'Watch GitHub issues',
      mode: 'standing',
      expires_at: '2026-08-01T00:00:00Z'
    })
    expect(commandFromArgs(['list', '--limit', '20'])).toEqual({ operation: 'list', limit: 20 })
    expect(commandFromArgs(['cancel', '--id', '123e4567-e89b-42d3-a456-426614174000'])).toEqual({
      operation: 'cancel',
      webhook_endpoint_id: '123e4567-e89b-42d3-a456-426614174000'
    })
    expect(() => commandFromArgs(['list', '--limit', '101'])).toThrow()
    expect(() => commandFromArgs(['list', '--automation-job-id', '1000'])).toThrow('unknown webhook CLI option')
    expect(() => commandFromArgs(['create', '--label', 'Watch', '--bogus', 'value'])).toThrow(
      'unknown webhook CLI option'
    )
  })

  it('forwards commands to the run-bound requester without generating a token', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-webhook-cli-'))
    const requests: Array<{ method: WebhookRPCMethod; payload: Record<string, unknown> }> = []
    const requestWebhookRPC = (async (method, payload) => {
      requests.push({ method, payload })
      return { status: 'ok' }
    }) as WebhookRPCRequester
    const bridge = startWebhookCLIBridge({
      requestWebhookRPC,
      socketRoot: root
    })

    try {
      await requestWebhookCLI(bridge.socketPath, {
        operation: 'create',
        label: 'Watch GitHub issues',
        mode: 'standing',
        expires_at: '2026-08-01T00:00:00Z'
      })
      await requestWebhookCLI(bridge.socketPath, { operation: 'list', limit: 10 })
      await requestWebhookCLI(bridge.socketPath, {
        operation: 'cancel',
        webhook_endpoint_id: '123e4567-e89b-42d3-a456-426614174001'
      })

      expect(requests.map(request => request.method)).toEqual([
        'webhook.endpoint.create',
        'webhook.endpoint.list',
        'webhook.endpoint.cancel'
      ])
      expect(requests[0]!.payload).not.toHaveProperty('token')
      expect(requests[0]!.payload).toMatchObject({
        label: 'Watch GitHub issues',
        mode: 'standing',
        expiresAt: '2026-08-01T00:00:00Z'
      })
      expect(requests[0]!.payload).not.toHaveProperty('replyRouteJson')
      expect(requests[1]!.payload).toEqual({ limit: 10 })
      expect(requests[2]!.payload).toEqual({
        webhookEndpointId: '123e4567-e89b-42d3-a456-426614174001'
      })
    } finally {
      bridge.close()
      rmSync(root, { recursive: true, force: true })
    }
  })

  it('serves the full contract help for shim-prefixed and bare help requests', () => {
    expect(helpRequested(['create', '--help'])).toBe(true)
    expect(helpRequested(['list', '-h'])).toBe(true)
    expect(helpRequested(['--help'])).toBe(true)
    expect(helpRequested(['create', '--label', 'Watch'])).toBe(false)

    const normalized = WEBHOOK_CLI_HELP.replace(/\s+/g, ' ')
    expect(normalized).toContain('authorizes wake-ups, nothing else')
    expect(normalized).toContain('durable inside Ankole before the sender receives 2xx')
    expect(normalized).toContain('capped at 1 MiB')
    expect(normalized).toContain('returned exactly once')
    expect(normalized).toContain('The command is not idempotent')
    expect(normalized).toContain('the script consumes the delivery instead')
    expect(normalized).toContain('a reconciliation checkback exists before the external object is created')
    expect(normalized).toContain('teardown removes the external object first, then cancels the endpoint')
  })

  it('rejects create when the current turn has no provider reply route', async () => {
    const root = mkdtempSync(join(tmpdir(), 'ankole-webhook-cli-'))
    const requestWebhookRPC = (async () => {
      throw new Error('requires a provider reply route')
    }) as WebhookRPCRequester
    const bridge = startWebhookCLIBridge({ requestWebhookRPC, socketRoot: root })

    try {
      await expect(
        requestWebhookCLI(bridge.socketPath, {
          operation: 'create',
          label: 'No route',
          mode: 'one_shot',
          expires_at: '2026-08-01T00:00:00Z'
        })
      ).rejects.toThrow('requires a provider reply route')
    } finally {
      bridge.close()
      rmSync(root, { recursive: true, force: true })
    }
  })
})
