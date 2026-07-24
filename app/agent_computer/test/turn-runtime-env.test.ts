import { createHmac } from 'node:crypto'
import { describe, expect, it } from 'bun:test'
import {
  buildTurnRuntimeEnv,
  CURRENT_ACTOR_SENDER_PRINCIPAL_ENV,
  LARK_PROFILE_ENV
} from '../src/core/turns/turn_runtime_env'
import type { TurnStart } from '../src/lanes/actor_lane'

describe('turn runtime environment', () => {
  it('derives an opaque Lark profile without exposing the Principal UID or worker key', () => {
    const principalUID = 'human-alice'
    const workerAuthKey = 'worker-secret'
    const env = buildTurnRuntimeEnv(turnStart({ [CURRENT_ACTOR_SENDER_PRINCIPAL_ENV]: principalUID }), workerAuthKey)
    const digest = createHmac('sha256', workerAuthKey).update(principalUID, 'utf8').digest('base64url')

    expect(env).toEqual({
      [CURRENT_ACTOR_SENDER_PRINCIPAL_ENV]: principalUID,
      [LARK_PROFILE_ENV]: `ankole-u-${digest}`
    })
    expect(env[LARK_PROFILE_ENV]).not.toContain(principalUID)
    expect(env[LARK_PROFILE_ENV]).not.toContain(workerAuthKey)
    expect(env[LARK_PROFILE_ENV]!.length).toBeLessThanOrEqual(64)
  })

  it('uses both the worker key and Principal UID as derivation inputs', () => {
    const first = buildTurnRuntimeEnv(
      turnStart({ [CURRENT_ACTOR_SENDER_PRINCIPAL_ENV]: 'human-alice' }),
      'worker-secret'
    )
    const otherPrincipal = buildTurnRuntimeEnv(
      turnStart({ [CURRENT_ACTOR_SENDER_PRINCIPAL_ENV]: 'human-bob' }),
      'worker-secret'
    )
    const otherWorker = buildTurnRuntimeEnv(
      turnStart({ [CURRENT_ACTOR_SENDER_PRINCIPAL_ENV]: 'human-alice' }),
      'other-worker-secret'
    )

    expect(first[LARK_PROFILE_ENV]).not.toBe(otherPrincipal[LARK_PROFILE_ENV])
    expect(first[LARK_PROFILE_ENV]).not.toBe(otherWorker[LARK_PROFILE_ENV])
  })

  it('does not derive a profile for unattended turns', () => {
    expect(buildTurnRuntimeEnv(turnStart({}), 'worker-secret')).toEqual({})
  })

  it('rejects invalid names, values, and control-plane profile overrides', () => {
    expect(() => buildTurnRuntimeEnv(turnStart({ NOT_RUNTIME: 'value' }), 'worker-secret')).toThrow(/ANKOLE_RUNTIME_/)
    expect(() =>
      buildTurnRuntimeEnv(turnStart({ [CURRENT_ACTOR_SENDER_PRINCIPAL_ENV]: 'bad\0uid' }), 'worker-secret')
    ).toThrow(/value is invalid/)
    expect(() => buildTurnRuntimeEnv(turnStart({ [LARK_PROFILE_ENV]: 'spoof' }), 'worker-secret')).toThrow(
      /reserved to Agent Computer/
    )
    expect(() =>
      buildTurnRuntimeEnv(
        turnStart({ ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY: 'must-not-enter-the-turn' }),
        'worker-secret'
      )
    ).toThrow(/reserved to Agent Computer/)
  })
})

function turnStart(runtimeEnv: Record<string, string>): TurnStart {
  return { runtime_env: runtimeEnv } as TurnStart
}
