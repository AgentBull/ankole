export type PodRuntimePlatform = 'macos' | 'windows' | 'linux'

export type DesktopWorkspaceSummary = {
  workspaceKey: string
  podOrigin: string
  siteOrigin: string
  tenantId: string
  tenantSlug: string
  tenantDisplayName: string
  tenantAvatarUrl?: string | null
  principalUid: string
  principalDisplayName: string
  principalAvatarUrl?: string | null
}

export type PodEventStream = Pick<EventTarget, 'addEventListener'> & {
  close: () => void
  onopen: ((this: EventSource, ev: Event) => unknown) | null
  onerror: ((this: EventSource, ev: Event) => unknown) | null
}

export type PodDesktopBridgeHooks = {
  workspaces?: DesktopWorkspaceSummary[]
  webSocketTransport?: new (endpoint: string) => object
  openEventStream?: (target: string | URL) => PodEventStream
  onSessionExpired?: () => void
  onSwitchWorkspace?: (workspaceKey: string) => Promise<void> | void
  onAddWorkspace?: () => Promise<void> | void
  onSignOutWorkspace?: (workspaceKey?: string) => Promise<void> | void
  onSignOutAllWorkspaces?: () => Promise<void> | void
  onOpenExternal?: (url: string) => Promise<void> | void
  onExportPDF?: (suggestedFileName?: string) => Promise<boolean>
}

export type PodRuntimeBootstrap = {
  mode: 'desktop'
  platform: PodRuntimePlatform
  workspaceKey: string
  version?: string
  podOrigin: string
  siteOrigin: string
  tenantId: string
  tenantSlug?: string
  tenantDisplayName?: string
  tenantAvatarUrl?: string | null
  principalUid: string
  principalDisplayName?: string
  principalAvatarUrl?: string | null
  activePlugins: string[]
  features: Record<string, boolean>
  locale: string
} & PodDesktopBridgeHooks

let runtimeBootstrap: PodRuntimeBootstrap | undefined
const listeners = new Set<() => void>()

export function getPodRuntimeBootstrap(): PodRuntimeBootstrap | undefined {
  return runtimeBootstrap
}

export function setPodRuntimeBootstrap(next: PodRuntimeBootstrap | undefined): void {
  runtimeBootstrap = next
  if (typeof document !== 'undefined' && document.documentElement) {
    if (next) {
      document.documentElement.dataset.ankoleDesktop = next.platform
      if (next.locale) document.documentElement.lang = next.locale
    } else {
      delete document.documentElement.dataset.ankoleDesktop
    }
  }
  for (const listener of listeners) listener()
}

export function updatePodRuntimeBootstrap(patch: Partial<PodRuntimeBootstrap>): void {
  if (!runtimeBootstrap) return
  setPodRuntimeBootstrap({ ...runtimeBootstrap, ...patch })
}

export function subscribePodRuntimeBootstrap(listener: () => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function isDesktopRuntime(): boolean {
  return runtimeBootstrap?.mode === 'desktop'
}

export function openPodEventStream(target: string | URL): PodEventStream {
  if (runtimeBootstrap?.openEventStream) {
    return runtimeBootstrap.openEventStream(target)
  }
  return new EventSource(target)
}

function browserOrigin(): string {
  if (typeof window !== 'undefined' && window.location.origin && window.location.origin !== 'null') {
    return window.location.origin
  }
  return 'http://localhost'
}

export function podPublicOrigin(): string {
  if (runtimeBootstrap?.podOrigin) return runtimeBootstrap.podOrigin
  return browserOrigin()
}

export function podSiteOrigin(): string {
  if (runtimeBootstrap?.siteOrigin) return runtimeBootstrap.siteOrigin
  if (typeof document !== 'undefined') {
    const meta = document.querySelector<HTMLMetaElement>('meta[name="ankole-site-origin"]')?.content
    if (meta) return meta
  }
  return browserOrigin()
}
