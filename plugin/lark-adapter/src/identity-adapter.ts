import * as lark from '@larksuiteoapi/node-sdk'
import type {
  BullXIdentityProviderAdapter,
  BullXIdentityProviderAdapterFactoryContext,
  BullXIdentityProviderFullSyncSnapshot,
  BullXIdentityProviderGroupRecord,
  BullXIdentityProviderUserRecord
} from '@agentbull/bullx-sdk/plugins'
import { LarkAdapterConfigError, type LarkIdentityProviderConfig } from './config'
import { sharedLarkConnections, type LarkConnectionLease } from './connection'
import {
  accountsBaseUrl,
  asRecord,
  assertLarkSuccess,
  compactJsonObject,
  isIgnorableContactSyncError,
  larkErrorSummary,
  larkLoggerFromRuntimeLogger,
  mapDepartmentRecord,
  mapUserRecord,
  mergeUserRecord,
  normalizePhone,
  optionalString,
  requireNonEmptyContactPage,
  sdkDomain
} from './lark-helpers'

export class BullXLarkIdentityProviderAdapter implements BullXIdentityProviderAdapter {
  private readonly client: lark.Client
  private connectionLease: LarkConnectionLease | undefined

  constructor(
    private readonly context: BullXIdentityProviderAdapterFactoryContext,
    private readonly config: LarkIdentityProviderConfig
  ) {
    this.client = new lark.Client({
      appId: config.appId,
      appSecret: config.appSecret,
      domain: sdkDomain(config.domain)
    })
  }

  buildOidcAuthorizationUrl(input: { redirectUri: string; state: string }): string {
    if (!this.config.oidc.enabled) throw new LarkAdapterConfigError('Lark OIDC is disabled')

    const params = new URLSearchParams({
      client_id: this.config.appId,
      redirect_uri: input.redirectUri,
      response_type: 'code',
      scope: this.config.oidc.scopes.join(' '),
      state: input.state
    })

    return `${accountsBaseUrl(this.config.domain)}/open-apis/authen/v1/authorize?${params.toString()}`
  }

  async completeOidcLogin(input: { code: string }): Promise<{ user: BullXIdentityProviderUserRecord }> {
    if (!this.config.oidc.enabled) throw new LarkAdapterConfigError('Lark OIDC is disabled')

    const token = await this.client.authen.oidcAccessToken.create({
      data: {
        grant_type: 'authorization_code',
        code: input.code
      }
    })
    assertLarkSuccess(token, 'oidc access token')

    const accessToken = token.data?.access_token
    if (!accessToken) throw new LarkAdapterConfigError('Lark OIDC access token response is missing access_token')

    const userInfo = await this.client.authen.userInfo.get({}, lark.withUserAccessToken(accessToken))
    assertLarkSuccess(userInfo, 'oidc user info')
    const user = await this.hydrateUser(userInfo.data)
    if (!user) throw new LarkAdapterConfigError('Lark OIDC user info is missing user_id')

    return { user }
  }

  async fullSync(): Promise<BullXIdentityProviderFullSyncSnapshot | undefined> {
    try {
      const groups = this.config.sync.departments ? await this.listDepartments() : []
      const users = this.config.sync.users ? await this.listUsers(groups) : []

      return { groups, users }
    } catch (error) {
      if (!isIgnorableContactSyncError(error)) throw error

      this.context.logger?.warn?.(
        { providerId: this.context.providerId, error: larkErrorSummary(error) },
        'Lark identity contact full sync skipped'
      )
      return undefined
    }
  }

  async start(): Promise<void> {
    this.connectionLease = await sharedLarkConnections.acquireIdentity(
      this.config,
      this,
      larkLoggerFromRuntimeLogger(this.context.logger)
    )
  }

  async stop(): Promise<void> {
    this.connectionLease?.release()
    this.connectionLease = undefined
  }

  private async listDepartments(): Promise<BullXIdentityProviderGroupRecord[]> {
    const groups: BullXIdentityProviderGroupRecord[] = []
    const iterator = await this.client.contact.department.childrenWithIterator({
      path: {
        department_id: '0'
      },
      params: {
        department_id_type: 'department_id',
        user_id_type: 'user_id',
        fetch_child: true,
        page_size: this.config.sync.pageSize
      }
    })

    for await (const page of iterator) {
      const departments = requireNonEmptyContactPage(page?.items, 'contact department children')
      for (const department of departments) {
        const group = mapDepartmentRecord(department)
        if (group) groups.push(group)
      }
    }

    return groups
  }

  private async listUsers(
    groups: readonly BullXIdentityProviderGroupRecord[]
  ): Promise<BullXIdentityProviderUserRecord[]> {
    const users = new Map<string, BullXIdentityProviderUserRecord>()
    const departmentIds = ['0', ...groups.map(group => group.externalId)]

    for (const departmentId of departmentIds) {
      const iterator = await this.client.contact.user.findByDepartmentWithIterator({
        params: {
          user_id_type: 'user_id',
          department_id_type: 'department_id',
          department_id: departmentId,
          page_size: this.config.sync.pageSize
        }
      })

      for await (const page of iterator) {
        const pageUsers = requireNonEmptyContactPage(page?.items, 'contact user find by department')
        for (const rawUser of pageUsers) {
          const user = mapUserRecord(rawUser)
          if (!user) continue

          users.set(user.externalId, mergeUserRecord(users.get(user.externalId), user))
        }
      }
    }

    return [...users.values()]
  }

  private async hydrateUser(input: unknown): Promise<BullXIdentityProviderUserRecord | undefined> {
    const direct = mapUserRecord(input)
    if (direct?.externalId) {
      const contact = await this.fetchContactUser(direct.externalId)
      return mergeUserRecord(direct, contact ?? direct)
    }

    const object = asRecord(input)
    const email = optionalString(object?.enterprise_email) ?? optionalString(object?.email)
    const mobile = optionalString(object?.mobile)
    if (!email && !mobile) return undefined

    const ids = await this.client.contact.user.batchGetId({
      data: {
        emails: email ? [email] : undefined,
        mobiles: mobile ? [mobile] : undefined,
        include_resigned: true
      },
      params: {
        user_id_type: 'user_id'
      }
    })
    assertLarkSuccess(ids, 'contact user batchGetId')
    const userId = ids.data?.user_list?.find(item => item.user_id)?.user_id
    if (!userId) return undefined

    const contact = await this.fetchContactUser(userId)
    return (
      contact ?? {
        externalId: userId,
        status: 'active',
        email,
        phone: normalizePhone(mobile),
        metadata: compactJsonObject({ source: 'oidc_user_info' })
      }
    )
  }

  private async fetchContactUser(userId: string): Promise<BullXIdentityProviderUserRecord | undefined> {
    const response = await this.client.contact.user.get({
      path: {
        user_id: userId
      },
      params: {
        user_id_type: 'user_id',
        department_id_type: 'department_id'
      }
    })
    assertLarkSuccess(response, 'contact user get')

    return mapUserRecord(response.data?.user)
  }

  async handleUserUpsertEvent(input: unknown): Promise<void> {
    const user = await this.hydrateUser(input)
    if (!user) {
      this.context.logger?.warn?.({ providerId: this.context.providerId, input }, 'Lark user event missing user_id')
      await this.context.syncSink.requestFullSync('lark.user_event_missing_user_id')
      return
    }

    await this.context.syncSink.upsertUser(user)
  }

  async handleUserDeletedEvent(input: unknown): Promise<void> {
    const user = await this.hydrateUser(input)
    if (!user) {
      this.context.logger?.warn?.(
        { providerId: this.context.providerId, input },
        'Lark deleted user event missing user_id'
      )
      await this.context.syncSink.requestFullSync('lark.deleted_user_event_missing_user_id')
      return
    }

    await this.context.syncSink.disableUser(user.externalId, user.metadata)
  }

  async handleDepartmentUpsertEvent(input: unknown): Promise<void> {
    const group = mapDepartmentRecord(input)
    if (!group) {
      await this.context.syncSink.requestFullSync('lark.department_event_missing_department_id')
      return
    }

    await this.context.syncSink.upsertGroup(group)
  }

  async handleDepartmentDeletedEvent(input: unknown): Promise<void> {
    const group = mapDepartmentRecord(input)
    if (!group) {
      await this.context.syncSink.requestFullSync('lark.department_deleted_event_missing_department_id')
      return
    }

    await this.context.syncSink.deleteGroup(group.externalId)
  }

  async handleContactScopeUpdated(): Promise<void> {
    await this.context.syncSink.requestFullSync('contact.scope.updated_v3')
  }
}
