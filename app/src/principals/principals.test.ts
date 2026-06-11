import { afterAll, beforeEach, describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { eq, inArray, like } = await import('drizzle-orm')
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
const { disablePrincipal, newPrincipalDomainRowId, PrincipalDomainError, updatePrincipalStatus } =
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
    const adapter = uid('feishu')
    const channelId = uid('tenant-1')
    const openId = uid('open-id-1')
    const unverifiedOpenId = uid('open-id-unverified')
    const agentOpenId = uid('agent-open-id')

    const identity = await createExternalIdentity({
      principalUid: human.principal.uid,
      kind: 'channel_actor',
      adapter,
      channelId,
      externalId: openId,
      verifiedAt: new Date(),
      metadata: { source: 'test' }
    })

    expect(identity.metadata).toEqual({ source: 'test' })
    await expect(
      createExternalIdentity({
        principalUid: human.principal.uid,
        kind: 'channel_actor',
        adapter,
        channelId,
        externalId: openId
      })
    ).rejects.toThrow()

    const resolved = await resolveChannelActor(adapter, channelId, openId)
    expect(resolved.uid).toBe(human.principal.uid)

    await createExternalIdentity({
      principalUid: human.principal.uid,
      kind: 'channel_actor',
      adapter,
      channelId,
      externalId: unverifiedOpenId
    })

    await expectDomainReason(resolveChannelActor(adapter, channelId, unverifiedOpenId), 'forbidden')

    const agent = await createAgent({ uid: uid('identity_agent') })
    await createExternalIdentity({
      principalUid: agent.principal.uid,
      kind: 'channel_actor',
      adapter,
      channelId,
      externalId: agentOpenId,
      verifiedAt: new Date()
    })
    await expectDomainReason(resolveChannelActor(adapter, channelId, agentOpenId), 'not_human')
  })

  it('syncs identity provider users, platform subjects, department groups, and ancestor memberships', async () => {
    const provider = uid('lark-main')
    const parentDepartment = uid('od_parent')
    const childDepartment = uid('od_child')
    const userId = uid('user_123')

    const stats = await applyIdentityProviderFullSync(provider, {
      groups: [
        {
          externalId: parentDepartment,
          name: 'Engineering'
        },
        {
          externalId: childDepartment,
          name: 'Platform',
          parentExternalId: parentDepartment
        }
      ],
      users: [
        {
          externalId: userId,
          status: 'active',
          displayName: 'Alice',
          email: `alice.${testPrefix}@example.com`,
          departmentExternalIds: [childDepartment],
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
      .where(eq(PrincipalExternalIdentities.provider, provider))
      .limit(1)
    expect(identity?.kind).toBe('platform_subject')
    expect(identity?.externalId).toBe(userId)
    expect(identity?.principalUid).toBe(userId)

    const memberships = await DB.select({ groupName: PrincipalGroups.name })
      .from(PrincipalGroupMemberships)
      .innerJoin(PrincipalGroups, eq(PrincipalGroups.id, PrincipalGroupMemberships.groupId))
      .where(eq(PrincipalGroupMemberships.principalUid, userId))
    expect(memberships.map(row => row.groupName).sort()).toEqual([
      `${provider}:department:${childDepartment}`,
      `${provider}:department:${parentDepartment}`
    ])

    await syncIdentityProviderUser(provider, {
      externalId: userId,
      status: 'active',
      displayName: 'Alice',
      email: `alice.${testPrefix}@example.com`,
      departmentExternalIds: [parentDepartment]
    })
    const updatedMemberships = await DB.select({ groupName: PrincipalGroups.name })
      .from(PrincipalGroupMemberships)
      .innerJoin(PrincipalGroups, eq(PrincipalGroups.id, PrincipalGroupMemberships.groupId))
      .where(eq(PrincipalGroupMemberships.principalUid, userId))
    expect(updatedMemberships.map(row => row.groupName).sort()).toEqual([`${provider}:department:${parentDepartment}`])

    await syncIdentityProviderUser(provider, {
      externalId: userId,
      status: 'disabled',
      displayName: 'Alice',
      departmentExternalIds: [parentDepartment]
    })
    const disabledMemberships = await DB.select({ groupName: PrincipalGroups.name })
      .from(PrincipalGroupMemberships)
      .innerJoin(PrincipalGroups, eq(PrincipalGroups.id, PrincipalGroupMemberships.groupId))
      .where(eq(PrincipalGroupMemberships.principalUid, userId))
    expect(disabledMemberships).toEqual([])

    await applyIdentityProviderFullSync(provider, { groups: [], users: [] })
    const [disabled] = await DB.select().from(Principals).where(eq(Principals.uid, userId)).limit(1)
    expect(disabled?.status).toBe('disabled')
  })

  it('lets chat and directory sync converge through one platform subject binding', async () => {
    const provider = uid('lark-main')
    const userId = uid('user_456')
    const chatObservation = await upsertPlatformSubjectHuman({
      provider,
      externalId: userId,
      displayName: 'Chat Alice',
      metadata: {
        source: 'message',
        open_id: 'ou_app_a'
      }
    })

    await syncIdentityProviderUser(provider, {
      externalId: userId,
      status: 'active',
      displayName: 'Directory Alice',
      email: `directory.${testPrefix}@example.com`,
      metadata: {
        union_id: 'on_union',
        tenant_key: 'tenant_1'
      }
    })

    const afterDirectory = await resolvePlatformSubject(provider, userId)
    expect(afterDirectory.uid).toBe(chatObservation.principal.uid)

    await upsertPlatformSubjectHuman({
      provider,
      externalId: userId,
      displayName: 'Chat Alice Again',
      metadata: {
        source: 'message',
        open_id: 'ou_app_b'
      }
    })

    const [identity] = await DB.select()
      .from(PrincipalExternalIdentities)
      .where(eq(PrincipalExternalIdentities.provider, provider))
    expect(identity?.principalUid).toBe(chatObservation.principal.uid)
    expect(identity?.metadata).toMatchObject({
      open_id: 'ou_app_b',
      union_id: 'on_union',
      tenant_key: 'tenant_1'
    })

    const [human] = await DB.select().from(HumanUsers).where(eq(HumanUsers.principalUid, chatObservation.principal.uid))
    expect(human?.email).toBe(`directory.${testPrefix}@example.com`)
  })

  it('does not let identity-provider full sync disable chat-only platform subjects', async () => {
    const chatObservation = await upsertPlatformSubjectHuman({
      provider: uid('lark-main'),
      externalId: uid('chat_only_user'),
      displayName: 'Chat-only user',
      metadata: {
        source: 'message'
      }
    })

    const stats = await applyIdentityProviderFullSync(uid('lark-main'), { groups: [], users: [] })
    const [principal] = await DB.select()
      .from(Principals)
      .where(eq(Principals.uid, chatObservation.principal.uid))
      .limit(1)

    expect(stats.usersDisabled).toBe(0)
    expect(principal?.status).toBe('active')
  })
})

describe('authorization', () => {
  it('authorizes direct, static group, computed group, and all_humans grants', async () => {
    const human = await createHuman({ uid: uid('auth_human') })
    const agentResource = `${testPrefix}:ai_agent:default`

    await createPermissionGrant({
      principalUid: human.principal.uid,
      resourcePattern: `${testPrefix}:ai_agent:**`,
      action: 'invoke',
      condition: 'context.request.env == "prod"'
    })
    expect(await allowed(human.principal.uid, agentResource, 'invoke', { env: 'prod' })).toBe(true)
    expect(await allowed(human.principal.uid, agentResource, 'invoke', { env: 'dev' })).toBe(false)
    expect(await allowed(human.principal.uid, agentResource, 'inspect')).toBe(false)

    const staticGroup = await createPrincipalGroup({ name: uid('operators') })
    await addPrincipalToGroup(human.principal.uid, staticGroup.id)
    await createPermissionGrant({
      groupId: staticGroup.id,
      resourcePattern: `${testPrefix}:ai_agent:*`,
      action: 'inspect'
    })
    await authorizeAll(human.principal.uid, agentResource, ['invoke', 'inspect'], { env: 'prod' })

    const computedGroup = await createPrincipalGroup({
      name: uid('computed'),
      kind: 'computed',
      computedCondition: `principal.uid == "${human.principal.uid}"`
    })
    await createPermissionGrant({
      groupId: computedGroup.id,
      resourcePattern: `${testPrefix}:web_console`,
      action: 'read'
    })
    await authorizePermission(human.principal.uid, `${testPrefix}:web_console:read`)

    const allHumans = await ensureBuiltInAllHumansGroup()
    await createPermissionGrant({
      groupId: allHumans.id,
      resourcePattern: `${testPrefix}:directory`,
      action: 'read'
    })
    expect(await allowed(human.principal.uid, `${testPrefix}:directory`, 'read')).toBe(true)
  })

  it('rejects invalid requests and fails closed for invalid persisted authorization data', async () => {
    const human = await createHuman({ uid: uid('invalid_auth_human') })

    await expectDomainReason(authorizePermission(human.principal.uid, 'missing_action'), 'invalid_request')
    await expectDomainReason(
      authorizePermission(human.principal.uid, `${testPrefix}:ai_agent:*:read`),
      'invalid_request'
    )

    await DB.insert(PermissionGrants).values({
      id: newPrincipalDomainRowId(),
      principalUid: human.principal.uid,
      resourcePattern: `${testPrefix}:ai_agent:[`,
      action: 'invoke',
      condition: 'true'
    })
    expect(await allowed(human.principal.uid, `${testPrefix}:ai_agent:default`, 'invoke')).toBe(false)

    await DB.insert(PermissionGrants).values({
      id: newPrincipalDomainRowId(),
      principalUid: human.principal.uid,
      resourcePattern: `${testPrefix}:ai_agent:**`,
      action: 'inspect',
      condition: 'principal..uid'
    })
    expect(await allowed(human.principal.uid, `${testPrefix}:ai_agent:default`, 'inspect')).toBe(false)
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

    try {
      await ensureRootInitOpen()
      await rootInitAdmin(human.principal.uid)
    } catch (error) {
      expect(error).toBeInstanceOf(PrincipalDomainError)
      expect((error as InstanceType<typeof PrincipalDomainError>).reason).toBe('root_init_closed')
      return
    }

    expect(await rootInitialized()).toBe(true)
    await expectDomainReason(ensureRootInitOpen(), 'root_init_closed')

    const second = await createHuman({ uid: uid('root_second') })
    await expectDomainReason(rootInitAdmin(second.principal.uid), 'root_init_closed')
  })

  it('allows disabling the last active human admin but keeps at least one admin membership', async () => {
    const first = await createHuman({ uid: uid('admin_first') })
    const second = await createHuman({ uid: uid('admin_second') })

    const admin = await ensureBuiltInAdminGroup()
    try {
      await rootInitAdmin(first.principal.uid)
    } catch (error) {
      expect(error).toBeInstanceOf(PrincipalDomainError)
      expect((error as InstanceType<typeof PrincipalDomainError>).reason).toBe('root_init_closed')
      await addPrincipalToGroup(first.principal.uid, admin.id)
    }

    if (!(await hasAdminMembersOutside(admin.id, [first.principal.uid, second.principal.uid]))) {
      await expectDomainReason(removePrincipalFromGroup(first.principal.uid, admin.id), 'last_admin_member')
    }

    await addPrincipalToGroup(second.principal.uid, admin.id)
    await disablePrincipal(first.principal.uid)
    const disabledSecond = await disablePrincipal(second.principal.uid)
    expect(disabledSecond.status).toBe('disabled')
    if (await hasActiveHumanAdminOutside(admin.id, [first.principal.uid, second.principal.uid])) {
      await removePrincipalFromGroup(second.principal.uid, admin.id)
    } else {
      await expectDomainReason(removePrincipalFromGroup(second.principal.uid, admin.id), 'last_active_human_admin')
    }
  })
})

async function clearPrincipalTables() {
  const groups = await DB.select({ id: PrincipalGroups.id })
    .from(PrincipalGroups)
    .where(like(PrincipalGroups.name, `${testPrefix}%`))
  const groupIds = groups.map(group => group.id)

  await DB.delete(PermissionGrants).where(like(PermissionGrants.resourcePattern, `${testPrefix}%`))
  await DB.delete(PermissionGrants).where(like(PermissionGrants.principalUid, `${testPrefix}%`))
  if (groupIds.length > 0) await DB.delete(PermissionGrants).where(inArray(PermissionGrants.groupId, groupIds))

  await DB.delete(PrincipalGroupMemberships).where(like(PrincipalGroupMemberships.principalUid, `${testPrefix}%`))
  if (groupIds.length > 0) {
    await DB.delete(PrincipalGroupMemberships).where(inArray(PrincipalGroupMemberships.groupId, groupIds))
    await DB.delete(PrincipalGroupExternalBindings).where(inArray(PrincipalGroupExternalBindings.groupId, groupIds))
  }
  await DB.delete(PrincipalGroupExternalBindings).where(like(PrincipalGroupExternalBindings.provider, `${testPrefix}%`))

  await DB.delete(PrincipalExternalIdentities).where(like(PrincipalExternalIdentities.principalUid, `${testPrefix}%`))
  await DB.delete(PrincipalExternalIdentities).where(like(PrincipalExternalIdentities.provider, `${testPrefix}%`))
  await DB.delete(PrincipalExternalIdentities).where(like(PrincipalExternalIdentities.adapter, `${testPrefix}%`))
  await DB.delete(PrincipalExternalIdentities).where(like(PrincipalExternalIdentities.channelId, `${testPrefix}%`))
  await DB.delete(PrincipalExternalIdentities).where(like(PrincipalExternalIdentities.externalId, `${testPrefix}%`))

  await DB.delete(Agents).where(like(Agents.uid, `${testPrefix}%`))
  await DB.delete(HumanUsers).where(like(HumanUsers.principalUid, `${testPrefix}%`))
  await DB.delete(PrincipalGroups).where(like(PrincipalGroups.name, `${testPrefix}%`))
  await DB.delete(Principals).where(like(Principals.uid, `${testPrefix}%`))
}

async function hasAdminMembersOutside(groupId: string, ignoredPrincipalUids: string[]): Promise<boolean> {
  const rows = await DB.select({ principalUid: PrincipalGroupMemberships.principalUid })
    .from(PrincipalGroupMemberships)
    .where(eq(PrincipalGroupMemberships.groupId, groupId))
  return rows.some(row => !ignoredPrincipalUids.includes(row.principalUid))
}

async function hasActiveHumanAdminOutside(groupId: string, ignoredPrincipalUids: string[]): Promise<boolean> {
  const rows = await DB.select({ principalUid: Principals.uid, status: Principals.status, type: Principals.type })
    .from(PrincipalGroupMemberships)
    .innerJoin(Principals, eq(Principals.uid, PrincipalGroupMemberships.principalUid))
    .where(eq(PrincipalGroupMemberships.groupId, groupId))
  return rows.some(
    row => !ignoredPrincipalUids.includes(row.principalUid) && row.type === 'human' && row.status === 'active'
  )
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
