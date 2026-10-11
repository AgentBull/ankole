const storageKey = 'ankole.console.data-tenant'

export function dataTenantID(): string | null {
  return window.sessionStorage.getItem(storageKey)
}

export function clearDataTenant(): void {
  window.sessionStorage.removeItem(storageKey)
}

/** Commit a selection only after navigation succeeded and the old document is gone. */
export function applyDataTenantNavigation(): void {
  const url = new URL(window.location.href)
  if (!url.searchParams.has('data_tenant')) return
  const tenantID = url.searchParams.get('data_tenant')
  if (tenantID) window.sessionStorage.setItem(storageKey, tenantID)
  else clearDataTenant()
  url.searchParams.delete('data_tenant')
  window.history.replaceState(window.history.state, '', url)
}

/** A cancelled beforeunload must leave both this document and its tenant unchanged. */
export function selectDataTenant(tenantID: string | null): void {
  const url = new URL(window.location.href)
  url.searchParams.set('data_tenant', tenantID ?? '')
  window.location.assign(url)
}

/** Only the console's tenant resource requests carry the selected data context. */
export function withDataContext(fetch: typeof globalThis.fetch): typeof globalThis.fetch {
  const scopedFetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
    const request = new Request(input, init)
    const url = new URL(request.url)
    const path = url.pathname
    const selected = dataTenantID()
    if (
      selected &&
      url.origin === window.location.origin &&
      path.startsWith('/api/v1/') &&
      !path.startsWith('/api/v1/site/') &&
      !request.headers.has('x-ankole-tenant')
    ) {
      request.headers.set('x-ankole-tenant', selected)
    }
    const response = await fetch(request)
    if (selected && request.headers.get('x-ankole-tenant') === selected && response.status === 404) {
      const payload = await response
        .clone()
        .json()
        .catch(() => null)
      if (payload?.error?.code === 'data_tenant_unavailable') selectDataTenant(null)
    }
    return response
  }
  return scopedFetch as typeof globalThis.fetch
}
