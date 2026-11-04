import { compactRecord } from '@agentbull/active-support'
import type { LoginProvidersData } from '../common/api/generated/types.gen'
import { localReturnPath } from '../common/pod-url'

export interface LoginContext {
  oauthRequest?: string
  tenantID?: string
  consoleReturn?: string
  returnTo?: string
  prompt?: string
  reauth?: string
  invitation?: string
  invitationToken?: string
}

const authorizationQueryKeys = [
  'oauth_request',
  'console_return',
  'return_to',
  'prompt',
  'reauth',
  'invitation',
  'invitation_token'
] as const

function readParam(params: URLSearchParams, key: string): string | undefined {
  const value = params.get(key)
  return value && value.length > 0 ? value : undefined
}

export function readLoginSearch(search = window.location.search): {
  query: NonNullable<LoginProvidersData['query']>
  context: LoginContext
  authorizationParams: URLSearchParams
} {
  const params = new URLSearchParams(search)
  const oauthRequest = readParam(params, 'oauth_request')
  const tenantID = readParam(params, 'tenant_id')
  const consoleReturn = readParam(params, 'console_return')
  const returnTo = readParam(params, 'return_to')
  const prompt = readParam(params, 'prompt')
  const switchAccount = readParam(params, 'switch')
  const reauth = readParam(params, 'reauth')
  const invitation = readParam(params, 'invitation')
  const invitationToken = readParam(params, 'invitation_token')

  const query: NonNullable<LoginProvidersData['query']> = compactRecord({
    oauth_request: oauthRequest,
    tenant_id: tenantID,
    console_return: consoleReturn,
    prompt,
    switch: switchAccount,
    reauth,
    invitation,
    invitation_token: invitationToken
  })

  const context: LoginContext = compactRecord({
    oauthRequest,
    tenantID,
    consoleReturn,
    returnTo,
    prompt,
    reauth,
    invitation,
    invitationToken
  })

  const authorizationParams = new URLSearchParams()
  for (const key of authorizationQueryKeys) {
    const value = readParam(params, key)
    if (value) authorizationParams.set(key, value)
  }

  return { query, context, authorizationParams }
}

export function loginContextKey(context?: LoginContext): string {
  const origin = typeof window === 'undefined' ? '' : window.location.origin
  const pathname = typeof window === 'undefined' ? '' : window.location.pathname
  return [
    origin,
    pathname,
    context?.oauthRequest ?? '',
    context?.tenantID ?? '',
    context?.consoleReturn ?? '',
    context?.reauth ?? '',
    context?.invitation ?? '',
    context?.invitationToken ?? ''
  ].join(':')
}

/** The post-logout sign-in button only follows a local, non-looping destination. */
export function signInReturnTo(value: string | null, origin: string): string {
  const path = localReturnPath(value, origin)
  return path && !path.startsWith('/sessions/logged-out') ? path : '/sessions/new'
}
