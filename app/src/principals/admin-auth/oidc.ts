export function identityProviderOidcCallbackPath(providerId: string): string {
  return `/sessions/oidc/${encodeURIComponent(providerId)}/callback`
}

export function identityProviderOidcRedirectUri(publicBaseUrl: string, providerId: string): string {
  return `${normalizePublicBaseUrl(publicBaseUrl)}${identityProviderOidcCallbackPath(providerId)}`
}

export function requestPublicBaseUrl(request: Request): string {
  return new URL(request.url).origin
}

/**
 * Resolves the public base URL used for identity-provider redirects.
 *
 * During first setup there may be no persisted public URL yet, so request
 * origin is the only usable bootstrap value. Once setup saves a provider, the
 * configured URL wins; this keeps callback URIs stable behind reverse proxies
 * and avoids mixing localhost/admin domains across OIDC requests.
 */
export async function resolveIdentityProviderPublicBaseUrl(request: Request): Promise<string> {
  const [{ appConfigService }, { AdminAuthPublicBaseUrlConfig }] = await Promise.all([
    import('@/config/app-configure'),
    import('./config')
  ])
  return normalizePublicBaseUrl(
    (await appConfigService.get(AdminAuthPublicBaseUrlConfig)) ?? requestPublicBaseUrl(request)
  )
}

function normalizePublicBaseUrl(publicBaseUrl: string): string {
  return publicBaseUrl.replace(/\/+$/, '')
}
