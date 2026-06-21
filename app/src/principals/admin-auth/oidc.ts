/**
 * Builds the per-provider callback path the identity provider redirects back to.
 *
 * The provider id is path-encoded because it is operator-supplied and becomes
 * part of a URL. The shape `/sessions/oidc/:providerId/callback` is a fixed
 * contract: it is what is registered at the provider and what the callback route
 * in `api-routes.ts` listens on, so it must not drift between the two sides.
 */
export function identityProviderOidcCallbackPath(providerId: string): string {
  return `/sessions/oidc/${encodeURIComponent(providerId)}/callback`
}

/**
 * Joins the resolved public base URL with the provider callback path to form the
 * absolute redirect URI handed to the provider and echoed back in the state
 * cookie for later equality checks.
 */
export function identityProviderOidcRedirectUri(publicBaseUrl: string, providerId: string): string {
  return `${normalizePublicBaseUrl(publicBaseUrl)}${identityProviderOidcCallbackPath(providerId)}`
}

/** Origin (scheme + host + port) of the incoming request, used as the bootstrap base URL. */
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

/**
 * Strips trailing slashes so the base URL concatenates cleanly with a path that
 * already starts with `/`, avoiding a doubled slash in the redirect URI. The
 * configured value and the request origin both flow through here so a stray
 * trailing slash in operator config cannot change the redirect URI that the
 * provider compares against.
 */
function normalizePublicBaseUrl(publicBaseUrl: string): string {
  return publicBaseUrl.replace(/\/+$/, '')
}
