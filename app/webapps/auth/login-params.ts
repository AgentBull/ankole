import { compactRecord } from '@agentbull/active-support'
import type { LoginProvidersData } from '../common/api/generated/types.gen'

export interface LoginContext {
  oauthRequest?: string
  tenantID?: string
  purpose?: string
  returnTo?: string
  prompt?: string
  reauth?: string
  invitation?: string
  invitationToken?: string
}

const authorizationQueryKeys = [
  'oauth_request',
  'purpose',
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
  const purpose = readParam(params, 'purpose')
  const returnTo = readParam(params, 'return_to')
  const prompt = readParam(params, 'prompt')
  const switchAccount = readParam(params, 'switch')
  const reauth = readParam(params, 'reauth')
  const invitation = readParam(params, 'invitation')
  const invitationToken = readParam(params, 'invitation_token')

  const query: NonNullable<LoginProvidersData['query']> = compactRecord({
    oauth_request: oauthRequest,
    tenant_id: tenantID,
    purpose,
    prompt,
    switch: switchAccount,
    reauth,
    invitation,
    invitation_token: invitationToken
  })

  const context: LoginContext = compactRecord({
    oauthRequest,
    tenantID,
    purpose,
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
    context?.purpose ?? '',
    context?.reauth ?? '',
    context?.invitation ?? '',
    context?.invitationToken ?? ''
  ].join(':')
}
