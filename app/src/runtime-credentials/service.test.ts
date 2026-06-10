import { afterAll, describe, expect, it } from 'bun:test'
import { and, eq, inArray } from 'drizzle-orm'
import { loadTestEnvFiles } from '@/common/tests/load-test-env'

await loadTestEnvFiles()

const { DB } = await import('@/common/database')
const { Principals, RuntimeCredentials } = await import('@/common/db-schema')
const { createAgent } = await import('@/principals/agents/service')
const { deleteRuntimeCredential, materializeRuntimeCredential, resolveRuntimeCredential, setRuntimeCredential } =
  await import('./service')

const suffix = `${Date.now()}_${Math.random().toString(36).slice(2)}`.toLowerCase()
const agentUid = `credential_test_${suffix}`
const defaultPayload = '{"refresh_token":"default-secret"}'
const agentPayload = '{"refresh_token":"agent-secret"}'

afterAll(async () => {
  await DB.delete(RuntimeCredentials).where(
    inArray(RuntimeCredentials.consumerName, [`codex-${suffix}`, `materialize-${suffix}`])
  )
  await DB.delete(Principals).where(inArray(Principals.uid, [agentUid]))
})

describe('runtime credentials', () => {
  it('stores encrypted default credentials and resolves agent overrides', async () => {
    await createAgent({ uid: agentUid })
    await setRuntimeCredential({
      consumerKind: 'skill',
      consumerName: `codex-${suffix}`,
      credentialName: 'auth_json',
      scope: { kind: 'default' },
      payload: defaultPayload,
      payloadMediaType: 'application/json'
    })

    const [storedDefault] = await DB.select()
      .from(RuntimeCredentials)
      .where(and(eq(RuntimeCredentials.consumerName, `codex-${suffix}`), eq(RuntimeCredentials.scopeKind, 'default')))
      .limit(1)
    expect(storedDefault?.encryptedPayload).not.toContain('default-secret')
    expect(storedDefault?.payloadBlake3).toBeString()

    const resolvedDefault = await resolveRuntimeCredential({
      consumerKind: 'skill',
      consumerName: `codex-${suffix}`,
      credentialName: 'auth_json',
      agentUid
    })
    expect(resolvedDefault?.payload).toBe(defaultPayload)
    expect(resolvedDefault?.scope).toEqual({ kind: 'default' })

    await setRuntimeCredential({
      consumerKind: 'skill',
      consumerName: `codex-${suffix}`,
      credentialName: 'auth_json',
      scope: { kind: 'agent', agentUid },
      payload: agentPayload,
      payloadMediaType: 'application/json'
    })

    const resolvedAgent = await resolveRuntimeCredential({
      consumerKind: 'skill',
      consumerName: `codex-${suffix}`,
      credentialName: 'auth_json',
      agentUid
    })
    expect(resolvedAgent?.payload).toBe(agentPayload)
    expect(resolvedAgent?.scope).toEqual({ kind: 'agent', agentUid })

    await deleteRuntimeCredential({
      consumerKind: 'skill',
      consumerName: `codex-${suffix}`,
      credentialName: 'auth_json',
      scope: { kind: 'agent', agentUid }
    })
    const resolvedAfterDelete = await resolveRuntimeCredential({
      consumerKind: 'skill',
      consumerName: `codex-${suffix}`,
      credentialName: 'auth_json',
      agentUid
    })
    expect(resolvedAfterDelete?.payload).toBe(defaultPayload)
  })

  it('materializes credentials one-way into /workspace/temp', async () => {
    await setRuntimeCredential({
      consumerKind: 'skill',
      consumerName: `materialize-${suffix}`,
      credentialName: 'auth_json',
      scope: { kind: 'default' },
      payload: defaultPayload,
      payloadMediaType: 'application/json'
    })
    const writes: unknown[] = []
    const credential = await materializeRuntimeCredential({
      consumerKind: 'skill',
      consumerName: `materialize-${suffix}`,
      credentialName: 'auth_json',
      agentUid,
      computer: {
        async writeFiles(files: unknown[]) {
          writes.push(files)
        }
      },
      path: 'temp/.codex/auth.json'
    })

    expect(credential?.payload).toBe(defaultPayload)
    expect(writes).toEqual([[{ path: 'temp/.codex/auth.json', content: defaultPayload, mode: 0o600 }]])
  })
})
