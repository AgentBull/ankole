import 'reflect-metadata'
import { afterAll, beforeEach, describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { eq } = await import('drizzle-orm')
const { DB } = await import('../common/database')
const {
  Agents,
  HumanUsers,
  PermissionGrants,
  PrincipalExternalIdentities,
  PrincipalGroupExternalBindings,
  PrincipalGroupMemberships,
  PrincipalGroups,
  Principals
} = await import('../common/db-schema')
const { createAgent, listActiveAgents, updateAgent } = await import('./agents/service')
const { createExternalIdentity, resolveChannelActor, resolvePlatformSubject, upsertPlatformSubjectHuman } =
  await import('./external-identities/service')
const { createHuman } = await import('./human-users/service')
const { disablePrincipal, newPrincipalId, PrincipalDomainError, updatePrincipalStatus } =
  await import('./principals/service')
const { applyIdentityProviderFullSync, syncIdentityProviderUser } = await import('./identity-providers/service')
const {
  addPrincipalToGroup,
  allowed,
  authorizeAll,
  authorizePermission,
  ensureBuiltInAdminGroup,
  ensureBuiltInAllHumansGroup,
  ensureRootInitOpen,
  rootInitAdmin,
  rootInitialized
} = await import('./authorization/service')
const { createPermissionGrant } = await import('./authorization/grants')
const { createPrincipalGroup } = await import('./authorization/groups')
const { removePrincipalFromGroup } = await import('./authorization/memberships')

const testPrefix = `test_principal_${Date.now()}_${Math.random().toString(36).slice(2)}`

beforeEach(async () => {
  await clearPrincipalTables()
})

afterAll(async () => {
  await clearPrincipalTables()
})

describe('principal data model', () => {
  it('creates human principals and normalizes identity fields', async () => {
    const result = await createHuman({
      uid: uid('Human_User'),
      displayName: ' Alice ',
      email: ` Alice.${testPrefix}@Example.COM `,
      phone: '+15551234567'
    })

    expect(result.principal.uid).toBe(uid('human_user'))
    expect(result.principal.type).toBe('human')
    expect(result.humanUser.email).toBe(`alice.${testPrefix}@example.com`)
    expect(result.humanUser.phone).toBe('+15551234567')
    expect(result.principal.createdAt).toBeInstanceOf(Date)

    await expectDomainReason(
      createHuman({
        uid: uid('bad_phone'),
        phone: '555-1234'
      }),
      'invalid_request'
    )
  })

  it('creates agents with default type and metadata, updates metadata, and lists active agents by creation time', async () => {
    const creator = await createHuman({ uid: uid('creator') })
    const first = await createAgent({ uid: uid('agent_a'), createdByPrincipalUid: creator.principal.uid })
    await sleep(10)
    const second = await createAgent({ uid: uid('agent_b'), metadata: { tier: 'gold' } })

    expect(first.agent.type).toBe('llm_agentic_loop')
    expect(first.agent.metadata).toEqual({})
    expect(second.agent.metadata).toEqual({ tier: 'gold' })

    const updated = await updateAgent(first.principal.uid, {
      displayName: 'Agent A',
      metadata: { tier: 'silver' }
    })
    expect(updated.principal.displayName).toBe('Agent A')
    expect(updated.agent.metadata).toEqual({ tier: 'silver' })

    await updatePrincipalStatus(second.principal.uid, 'disabled')
    const activeAgents = await listActiveAgents()
    expect(activeAgents.map(row => row.agent.uid)).toEqual([first.agent.uid])

    await expectDomainReason(createAgent({ uid: uid('bad_agent'), metadata: [] as never }), 'invalid_request')
  })

  it('creates external identities, enforces uniqueness, and resolves verified active human channel actors', async () => {
    const human = await createHuman({ uid: uid('identity_human') })

    const identity = await createExternalIdentity({
      principalUid: human.principal.uid,
      kind: 'channel_actor',
      adapter: 'feishu',
      channelId: 'tenant-1',
      externalId: 'open-id-1',
      verifiedAt: new Date(),
      metadata: { source: 'test' }
    })

    expect(identity.metadata).toEqual({ source: 'test' })
    await expect(
      createExternalIdentity({
        principalUid: human.principal.uid,
        kind: 'channel_actor',
        adapter: 'feishu',
        channelId: 'tenant-1',
        externalId: 'open-id-1'
      })
    ).rejects.toThrow()

    const resolved = await resolveChannelActor('feishu', 'tenant-1', 'open-id-1')
    expect(resolved.uid).toBe(human.principal.uid)

    await createExternalIdentity({
      principalUid: human.principal.uid,
      kind: 'channel_actor',
      adapter: 'feishu',
      channelId: 'tenant-1',
      externalId: 'open-id-unverified'
    })

    await expectDomainReason(resolveChannelActor('feishu', 'tenant-1', 'open-id-unverified'), 'forbidden')

    const agent = await createAgent({ uid: uid('identity_agent') })
    await createExternalIdentity({
      principalUid: agent.principal.uid,
      kind: 'channel_actor',
      adapter: 'feishu',
      channelId: 'tenant-1',
      externalId: 'agent-open-id',
      verifiedAt: new Date()
    })
    await expectDomainReason(resolveChannelActor('feishu', 'tenant-1', 'agent-open-id'), 'not_human')
  })

  it('syncs identity provider users, platform subjects, department groups, and ancestor memberships', async () => {
    const stats = await applyIdentityProviderFullSync('lark-main', {
      groups: [
        {
          externalId: 'od_parent',
          name: 'Engineering'
        },
        {
          externalId: 'od_child',
          name: 'Platform',
          parentExternalId: 'od_parent'
        }
      ],
      users: [
        {
          externalId: 'user_123',
          status: 'active',
          displayName: 'Alice',
          email: `alice.${testPrefix}@example.com`,
          departmentExternalIds: ['od_child'],
          metadata: {
            open_id: 'ou_app_scoped',
            union_id: 'on_union'
          }
        }
      ]
    })

    expect(stats.usersUpserted).toBe(1)
    expect(stats.groupsUpserted).toBe(2)
    expect(stats.membershipsUpserted).toBe(2)

    const [identity] = await DB.select()
      .from(PrincipalExternalIdentities)
      .where(eq(PrincipalExternalIdentities.provider, 'lark-main'))
      .limit(1)
    expect(identity?.kind).toBe('platform_subject')
    expect(identity?.externalId).toBe('user_123')
    expect(identity?.principalUid).toBe('user_123')

    const memberships = await DB.select({ groupName: PrincipalGroups.name })
      .from(PrincipalGroupMemberships)
      .innerJoin(PrincipalGroups, eq(PrincipalGroups.id, PrincipalGroupMemberships.groupId))
      .where(eq(PrincipalGroupMemberships.principalUid, 'user_123'))
    expect(memberships.map(row => row.groupName).sort()).toEqual([
      'lark-main:department:od_child',
      'lark-main:department:od_parent'
    ])

    await syncIdentityProviderUser('lark-main', {
      externalId: 'user_123',
      status: 'active',
      displayName: 'Alice',
      email: `alice.${testPrefix}@example.com`,
      departmentExternalIds: ['od_parent']
    })
    const updatedMemberships = await DB.select({ groupName: PrincipalGroups.name })
      .from(PrincipalGroupMemberships)
      .innerJoin(PrincipalGroups, eq(PrincipalGroups.id, PrincipalGroupMemberships.groupId))
      .where(eq(PrincipalGroupMemberships.principalUid, 'user_123'))
    expect(updatedMemberships.map(row => row.groupName).sort()).toEqual(['lark-main:department:od_parent'])

    await syncIdentityProviderUser('lark-main', {
      externalId: 'user_123',
      status: 'disabled',
      displayName: 'Alice',
      departmentExternalIds: ['od_parent']
    })
    const disabledMemberships = await DB.select({ groupName: PrincipalGroups.name })
      .from(PrincipalGroupMemberships)
      .innerJoin(PrincipalGroups, eq(PrincipalGroups.id, PrincipalGroupMemberships.groupId))
      .where(eq(PrincipalGroupMemberships.principalUid, 'user_123'))
    expect(disabledMemberships).toEqual([])

    await applyIdentityProviderFullSync('lark-main', { groups: [], users: [] })
    const [disabled] = await DB.select().from(Principals).where(eq(Principals.uid, 'user_123')).limit(1)
    expect(disabled?.status).toBe('disabled')
  })

  it('lets chat and directory sync converge through one platform subject binding', async () => {
    const chatObservation = await upsertPlatformSubjectHuman({
      provider: 'lark-main',
      externalId: 'user_456',
      displayName: 'Chat Alice',
      metadata: {
        source: 'message',
        open_id: 'ou_app_a'
      }
    })

    await syncIdentityProviderUser('lark-main', {
      externalId: 'user_456',
      status: 'active',
      displayName: 'Directory Alice',
      email: `directory.${testPrefix}@example.com`,
      metadata: {
        union_id: 'on_union',
        tenant_key: 'tenant_1'
      }
    })

    const afterDirectory = await resolvePlatformSubject('lark-main', 'user_456')
    expect(afterDirectory.uid).toBe(chatObservation.principal.uid)

    await upsertPlatformSubjectHuman({
      provider: 'lark-main',
      externalId: 'user_456',
      displayName: 'Chat Alice Again',
      metadata: {
        source: 'message',
        open_id: 'ou_app_b'
      }
    })

    const [identity] = await DB.select()
      .from(PrincipalExternalIdentities)
      .where(eq(PrincipalExternalIdentities.provider, 'lark-main'))
    expect(identity?.principalUid).toBe(chatObservation.principal.uid)
    expect(identity?.metadata).toMatchObject({
      open_id: 'ou_app_b',
      union_id: 'on_union',
      tenant_key: 'tenant_1'
    })

    const [human] = await DB.select().from(HumanUsers).where(eq(HumanUsers.principalUid, chatObservation.principal.uid))
    expect(human?.email).toBe(`directory.${testPrefix}@example.com`)
  })
})

describe('authorization', () => {
  it('authorizes direct, static group, computed group, and all_humans grants', async () => {
    const human = await createHuman({ uid: uid('auth_human') })

    await createPermissionGrant({
      principalUid: human.principal.uid,
      resourcePattern: 'ai_agent:**',
      action: 'invoke',
      condition: 'context.request.env == "prod"'
    })
    expect(await allowed(human.principal.uid, 'ai_agent:default', 'invoke', { env: 'prod' })).toBe(true)
    expect(await allowed(human.principal.uid, 'ai_agent:default', 'invoke', { env: 'dev' })).toBe(false)
    expect(await allowed(human.principal.uid, 'ai_agent:default', 'inspect')).toBe(false)

    const staticGroup = await createPrincipalGroup({ name: uid('operators') })
    await addPrincipalToGroup(human.principal.uid, staticGroup.id)
    await createPermissionGrant({
      groupId: staticGroup.id,
      resourcePattern: 'ai_agent:*',
      action: 'inspect'
    })
    await authorizeAll(human.principal.uid, 'ai_agent:default', ['invoke', 'inspect'], { env: 'prod' })

    const computedGroup = await createPrincipalGroup({
      name: uid('computed'),
      kind: 'computed',
      computedCondition: `principal.uid == "${human.principal.uid}"`
    })
    await createPermissionGrant({
      groupId: computedGroup.id,
      resourcePattern: 'web_console',
      action: 'read'
    })
    await authorizePermission(human.principal.uid, 'web_console:read')

    const allHumans = await ensureBuiltInAllHumansGroup()
    await createPermissionGrant({
      groupId: allHumans.id,
      resourcePattern: 'directory',
      action: 'read'
    })
    expect(await allowed(human.principal.uid, 'directory', 'read')).toBe(true)
  })

  it('rejects invalid requests and fails closed for invalid persisted authorization data', async () => {
    const human = await createHuman({ uid: uid('invalid_auth_human') })

    await expectDomainReason(authorizePermission(human.principal.uid, 'missing_action'), 'invalid_request')
    await expectDomainReason(authorizePermission(human.principal.uid, 'ai_agent:*:read'), 'invalid_request')

    await DB.insert(PermissionGrants).values({
      id: newPrincipalId(),
      principalUid: human.principal.uid,
      resourcePattern: 'ai_agent:[',
      action: 'invoke',
      condition: 'true'
    })
    expect(await allowed(human.principal.uid, 'ai_agent:default', 'invoke')).toBe(false)

    await DB.insert(PermissionGrants).values({
      id: newPrincipalId(),
      principalUid: human.principal.uid,
      resourcePattern: 'ai_agent:**',
      action: 'inspect',
      condition: 'principal..uid'
    })
    expect(await allowed(human.principal.uid, 'ai_agent:default', 'inspect')).toBe(false)
  })
})

describe('root and admin safety', () => {
  it('initializes built-in groups idempotently and blocks manual computed group membership', async () => {
    const human = await createHuman({ uid: uid('built_in_human') })

    const admin = await ensureBuiltInAdminGroup()
    const adminAgain = await ensureBuiltInAdminGroup()
    expect(adminAgain.id).toBe(admin.id)

    const allHumans = await ensureBuiltInAllHumansGroup()
    const allHumansAgain = await ensureBuiltInAllHumansGroup()
    expect(allHumansAgain.id).toBe(allHumans.id)

    await expectDomainReason(addPrincipalToGroup(human.principal.uid, allHumans.id), 'computed_group')
  })

  it('allows root init for the first active human admin and closes after membership exists', async () => {
    const human = await createHuman({ uid: uid('root_admin') })

    expect(await rootInitialized()).toBe(false)
    await ensureRootInitOpen()
    await rootInitAdmin(human.principal.uid)

    expect(await rootInitialized()).toBe(true)
    await expectDomainReason(ensureRootInitOpen(), 'root_init_closed')

    const second = await createHuman({ uid: uid('root_second') })
    await expectDomainReason(rootInitAdmin(second.principal.uid), 'root_init_closed')
  })

  it('allows disabling the last active human admin but keeps at least one admin membership', async () => {
    const first = await createHuman({ uid: uid('admin_first') })
    const second = await createHuman({ uid: uid('admin_second') })

    await rootInitAdmin(first.principal.uid)
    const admin = await ensureBuiltInAdminGroup()

    await expectDomainReason(removePrincipalFromGroup(first.principal.uid, admin.id), 'last_admin_member')

    await addPrincipalToGroup(second.principal.uid, admin.id)
    await disablePrincipal(first.principal.uid)
    const disabledSecond = await disablePrincipal(second.principal.uid)
    expect(disabledSecond.status).toBe('disabled')
    await expectDomainReason(removePrincipalFromGroup(second.principal.uid, admin.id), 'last_active_human_admin')
  })
})

async function clearPrincipalTables() {
  await DB.delete(PermissionGrants)
  await DB.delete(PrincipalGroupMemberships)
  await DB.delete(PrincipalGroupExternalBindings)
  await DB.delete(PrincipalExternalIdentities)
  await DB.delete(Agents)
  await DB.delete(HumanUsers)
  await DB.delete(PrincipalGroups)
  await DB.delete(Principals)
}

async function expectDomainReason(
  promise: Promise<unknown>,
  reason: InstanceType<typeof PrincipalDomainError>['reason']
) {
  try {
    await promise
  } catch (error) {
    expect(error).toBeInstanceOf(PrincipalDomainError)
    expect((error as InstanceType<typeof PrincipalDomainError>).reason).toBe(reason)
    return
  }

  throw new Error(`expected PrincipalDomainError(${reason})`)
}

function uid(name: string) {
  return `${testPrefix}_${name}`.toLowerCase()
}

function sleep(ms: number) {
  return new Promise(resolve => setTimeout(resolve, ms))
}
