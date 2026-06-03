import { describe, expect, it } from 'bun:test'
import {
  authzAuthorize,
  authzAuthorizeAll,
  authzMatchResourcePattern,
  authzValidateCondition,
  authzValidateResourcePattern
} from '../../index.js'

function principal(status = 'active') {
  return {
    uid: 'alice',
    type: 'human',
    status,
    displayName: 'Alice',
    avatarUrl: null
  }
}

function snapshot(overrides: Record<string, unknown> = {}) {
  return {
    principal: principal(),
    staticGroupIds: [],
    computedGroups: [],
    grants: [],
    resource: 'ai_agent:default',
    action: 'invoke',
    context: {},
    ...overrides
  }
}

describe('authz native addon', () => {
  it('validates CEL syntax and resource patterns', () => {
    expect(authzValidateCondition('true')).toBe(true)
    expect(authzValidateCondition('principal.type == "human"')).toBe(true)
    expect(() => authzValidateCondition('principal..type')).toThrow()

    expect(authzValidateResourcePattern('ai_agent:*')).toBe(true)
    expect(authzValidateResourcePattern('ai_agent:**')).toBe(true)
    expect(() => authzValidateResourcePattern('ai_agent:[')).toThrow()
  })

  it('matches resource patterns with colon-separated segments', () => {
    expect(authzMatchResourcePattern('ai_agent:*', 'ai_agent:default')).toBe(true)
    expect(authzMatchResourcePattern('ai_agent:*', 'ai_agent:default:thread')).toBe(false)
    expect(authzMatchResourcePattern('ai_agent:**', 'ai_agent:default:thread')).toBe(true)
  })

  it('allows a matching direct grant and denies wrong actions', () => {
    const allowed = authzAuthorize(
      snapshot({
        grants: [
          {
            id: 'grant-1',
            principalUid: 'alice',
            groupId: null,
            resourcePattern: 'ai_agent:**',
            action: 'invoke',
            condition: 'true'
          }
        ]
      })
    )

    expect(allowed.status).toBe('allow')

    const denied = authzAuthorize(
      snapshot({
        action: 'admin',
        grants: [
          {
            id: 'grant-1',
            principalUid: 'alice',
            groupId: null,
            resourcePattern: 'ai_agent:**',
            action: 'invoke',
            condition: 'true'
          }
        ]
      })
    )

    expect(denied.status).toBe('deny')
    expect(denied.deniedAction).toBe('admin')
  })

  it('evaluates computed groups before group grants', () => {
    const decision = authzAuthorize(
      snapshot({
        computedGroups: [
          {
            id: 'all_humans',
            condition: 'principal.type == "human" && principal.status == "active"'
          }
        ],
        grants: [
          {
            id: 'grant-1',
            principalUid: null,
            groupId: 'all_humans',
            resourcePattern: 'ai_agent:**',
            action: 'invoke',
            condition: 'true'
          }
        ]
      })
    )

    expect(decision.status).toBe('allow')
    expect(decision.effectiveGroupIds).toContain('all_humans')
  })

  it('fails closed for non-boolean and invalid persisted conditions', () => {
    const nonBoolean = authzAuthorize(
      snapshot({
        grants: [
          {
            id: 'grant-1',
            principalUid: 'alice',
            groupId: null,
            resourcePattern: 'ai_agent:**',
            action: 'invoke',
            condition: 'principal.uid'
          }
        ]
      })
    )

    expect(nonBoolean.status).toBe('deny')
    expect(nonBoolean.diagnostics[0].kind).toBe('condition_result_type')

    const invalid = authzAuthorize(
      snapshot({
        grants: [
          {
            id: 'grant-2',
            principalUid: 'alice',
            groupId: null,
            resourcePattern: 'ai_agent:**',
            action: 'invoke',
            condition: 'principal..uid'
          }
        ]
      })
    )

    expect(invalid.status).toBe('deny')
    expect(invalid.diagnostics[0].kind).toBe('condition_compile')
  })

  it('fails closed for invalid persisted resource patterns', () => {
    const decision = authzAuthorize(
      snapshot({
        grants: [
          {
            id: 'grant-1',
            principalUid: 'alice',
            groupId: null,
            resourcePattern: 'ai_agent:[',
            action: 'invoke',
            condition: 'true'
          }
        ]
      })
    )

    expect(decision.status).toBe('deny')
    expect(decision.diagnostics[0].kind).toBe('resource_pattern')
  })

  it('authorizes all requested actions or returns the first denied action', () => {
    const decision = authzAuthorizeAll({
      ...snapshot({
        grants: [
          {
            id: 'grant-1',
            principalUid: 'alice',
            groupId: null,
            resourcePattern: 'ai_agent:**',
            action: 'invoke',
            condition: 'true'
          },
          {
            id: 'grant-2',
            principalUid: 'alice',
            groupId: null,
            resourcePattern: 'ai_agent:**',
            action: 'inspect',
            condition: 'true'
          }
        ]
      }),
      actions: ['invoke', 'inspect']
    })

    expect(decision.status).toBe('allow')

    const denied = authzAuthorizeAll({
      ...snapshot({
        grants: [
          {
            id: 'grant-1',
            principalUid: 'alice',
            groupId: null,
            resourcePattern: 'ai_agent:**',
            action: 'invoke',
            condition: 'true'
          }
        ]
      }),
      actions: ['invoke', 'inspect']
    })

    expect(denied.status).toBe('deny')
    expect(denied.deniedAction).toBe('inspect')
  })

  it('denies disabled principals before grants can allow', () => {
    const decision = authzAuthorize(
      snapshot({
        principal: principal('disabled'),
        grants: [
          {
            id: 'grant-1',
            principalUid: 'alice',
            groupId: null,
            resourcePattern: 'ai_agent:**',
            action: 'invoke',
            condition: 'true'
          }
        ]
      })
    )

    expect(decision.status).toBe('principal_disabled')
  })
})
