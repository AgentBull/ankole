/** Identity belongs to this document. Changing the browser default cannot change it. */
export function authenticationRef(): string | undefined {
  return meta('ankole-authentication')
}

export function podID(): string | undefined {
  return meta('ankole-pod')
}

export function identityHeaders(): Record<string, string> {
  const authentication = authenticationRef()
  const tenant = podID()
  return {
    ...(authentication ? { 'x-ankole-authentication': authentication } : {}),
    ...(tenant ? { 'x-ankole-pod': tenant } : {})
  }
}

export function podLocation(path: string): { pathname: string; search: string } {
  const tenant = podID()
  return { pathname: path, search: tenant ? `?${new URLSearchParams({ tenant_id: tenant })}` : '' }
}

function meta(name: string): string | undefined {
  return typeof document === 'undefined'
    ? undefined
    : document.querySelector<HTMLMetaElement>(`meta[name="${name}"]`)?.content || undefined
}
