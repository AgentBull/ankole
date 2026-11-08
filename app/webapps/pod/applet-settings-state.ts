import * as api from './api/generated/sdk.gen'
import { contentKeys, type PageDetail } from './content-api'

export type AppletSettingsTab = 'environment' | 'automation' | 'webhooks' | 'logs' | 'functions'

export type OpenAppletSettingsRequest = {
  tab?: AppletSettingsTab
  jobID?: number
}

export const appletEnvKeys = {
  all: (pageID: string) => [...contentKeys.page(pageID), 'envs'] as const,
  list: (pageID: string, revision?: number) =>
    [...contentKeys.page(pageID), 'envs', 'list', ...(revision === undefined ? [] : [revision])] as const,
  status: (pageID: string, revision?: number) =>
    [...contentKeys.page(pageID), 'envs', 'status', ...(revision === undefined ? [] : [revision])] as const,
  matchesAnyPage: (queryKey: readonly unknown[]) => {
    const prefix = contentKeys.all
    return (
      queryKey.length >= prefix.length + 3 &&
      prefix.every((segment, index) => queryKey[index] === segment) &&
      queryKey[prefix.length] === 'page' &&
      queryKey[prefix.length + 2] === 'envs'
    )
  }
}

export function appletEnvsQuery(pageID: string, revision: number | undefined, enabled: boolean) {
  return {
    queryKey: appletEnvKeys.list(pageID, revision),
    queryFn: () => api.podAppletEnvs({ path: { page_id: pageID } }),
    enabled
  }
}

const settingsOpeners = new Map<string, (request: OpenAppletSettingsRequest) => void>()

export function registerAppletSettingsOpener(
  pageID: string,
  handler: (request: OpenAppletSettingsRequest) => void
): () => void {
  settingsOpeners.set(pageID, handler)
  return () => {
    if (settingsOpeners.get(pageID) === handler) {
      settingsOpeners.delete(pageID)
    }
  }
}

export function openAppletSettings(pageID: string, request: OpenAppletSettingsRequest = {}): boolean {
  const opener = settingsOpeners.get(pageID)
  if (!opener) return false
  opener(request)
  return true
}

export function canEditAppletEnv(detail: PageDetail): boolean {
  return !detail.page.deleted_at && detail.actions.includes('node_edit')
}

export function resolveAppletSettingsInitialTab({
  canEdit,
  hasAutomationLink,
  requestedTab
}: {
  canEdit: boolean
  hasAutomationLink: boolean
  requestedTab?: AppletSettingsTab
}): AppletSettingsTab {
  if (requestedTab && (requestedTab !== 'environment' || canEdit)) {
    return requestedTab
  }
  if (hasAutomationLink) {
    return 'automation'
  }
  return canEdit ? 'environment' : 'automation'
}
