import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import {
  contentKeys,
  pageAPI,
  pageQuery,
  type Page,
  type PageRole,
  type PageSharingDetail,
  type PageSharingUpdate,
  type PageType
} from '../content-api'
import {
  buildRemoveTarget,
  buildRoleUpsertPatch,
  partitionSharingGrants,
  type SharingGrant,
  type SharingScopeTab
} from '../state/page-sharing'
import { availableRolesForPage } from './sharing-primitives'

export type PageSharingMutations = {
  pending: boolean
  error: unknown
  clearError(): void
  setInheritPermissions(inherit_permissions: boolean): void
  changeGrantRole(grant: SharingGrant, role: PageRole, scope: SharingScopeTab): void
  removeGrant(grant: SharingGrant): void
  submitPatch(patch: PageSharingUpdate): Promise<PageSharingDetail>
}

export type PageSharingSession = {
  sharing?: PageSharingDetail
  sharingError: unknown
  retrySharing(): void
  pageType?: PageType
  hasParent: boolean
  roles: Partial<Record<PageRole, string>>
  restricted: boolean
  ordinaryGrants: SharingGrant[]
  advancedGrants: SharingGrant[]
  directByKey: ReadonlyMap<string, SharingGrant>
  mutations: PageSharingMutations
}

export function usePageSharing(
  pageID: string,
  { open, initialPage }: { open: boolean; initialPage?: Page }
): PageSharingSession {
  const client = useQueryClient()
  const cachedSharing = client.getQueryData<PageSharingDetail>(contentKeys.sharing(pageID))
  const sharingQuery = useQuery({
    queryKey: contentKeys.sharing(pageID),
    queryFn: ({ signal }) => pageAPI.sharing(pageID, signal),
    enabled: open
  })
  const pageDetail = useQuery({ ...pageQuery(pageID), enabled: open && !initialPage })
  const update = useMutation({
    mutationFn: (patch: PageSharingUpdate) => pageAPI.updateSharing(pageID, patch),
    onSuccess: async nextSharing => {
      client.setQueryData(contentKeys.sharing(pageID), nextSharing)
      await client.invalidateQueries({ queryKey: contentKeys.all })
    }
  })

  const page = initialPage ?? pageDetail.data?.page
  const pageType = page?.type
  const hasParent = Boolean(page?.parent_id)
  const roles = availableRolesForPage(pageType)
  const activeSharing = sharingQuery.data ?? cachedSharing
  const restricted = activeSharing
    ? activeSharing.scope_kind === 'private' || !activeSharing.inherit_permissions
    : Boolean(page?.private_owner_uid) || page?.inherit_permissions === false
  const { ordinaryGrants, advancedGrants, directByKey } = partitionSharingGrants(sharingQuery.data?.grants ?? [], roles)

  return {
    sharing: sharingQuery.data,
    sharingError: sharingQuery.error,
    retrySharing: () => void sharingQuery.refetch(),
    pageType,
    hasParent,
    roles,
    restricted,
    ordinaryGrants,
    advancedGrants,
    directByKey,
    mutations: {
      pending: update.isPending,
      error: update.error,
      clearError: () => update.reset(),
      setInheritPermissions: inherit_permissions => update.mutate({ inherit_permissions }),
      changeGrantRole: (grant, role, scope) => update.mutate(buildRoleUpsertPatch(grant, role, scope)),
      removeGrant: grant => update.mutate({ removes: [buildRemoveTarget(grant)] }),
      submitPatch: patch => update.mutateAsync(patch)
    }
  }
}
