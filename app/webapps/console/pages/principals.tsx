import {
  Avatar,
  AvatarFallback,
  AvatarImage,
  Badge,
  buttonVariants,
  cn,
  Skeleton,
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
  toast
} from '@ankole/uikit'
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { RiKey2Line } from '@remixicon/react'
import { useDeferredValue, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link, useParams } from 'react-router'
import {
  ankoleWebAuthZGroupControllerAddMemberMutation,
  ankoleWebAuthZGroupControllerIndexOptions,
  ankoleWebAuthZGroupControllerRemoveMemberMutation,
  ankoleWebPrincipalControllerGrantsOptions,
  ankoleWebPrincipalControllerGroupsOptions,
  ankoleWebPrincipalControllerIndexOptions,
  ankoleWebPrincipalControllerShowOptions
} from '../api/generated/@tanstack/react-query.gen'
import type { PrincipalItem } from '../api/generated/types.gen'
import { requestErrorMessage } from '../../common/request-errors'
import { AddMembershipPicker } from '../add-membership-picker'
import { BackLink, PageStack } from '../console-page'
import { ErrorBlock } from '../../common/error-block'
import { ConfirmDeleteButton, StatusIndicator } from '../console-form'
import { ResourceListPage, ResourceSearch, RowViewAction, SubNav } from '../console-list-page'
import { principalGroupDisplayName } from '../state/principal-group-text'
import { effectiveResourceSearchQuery, matchesResourceSearch } from '../state/resource-search'
import { useLocalIdentityProvider } from '../use-local-identity-provider'
import { PermissionGrantsSection } from './permission-grant-editor'
import { LocalPasswordSection } from './principal-local-password'

/**
 * Sibling views of the "Access" nav area.
 *
 * The side nav has one entry for access control and it lands on the group list,
 * so the principal list below was reachable only by typing its URL. Both lists
 * now carry this strip.
 */
export function AccessSubNav() {
  const { t } = useTranslation()
  return (
    <SubNav
      ariaLabel={t('console.aria.access_sections')}
      items={[
        { to: '/access/groups', label: t('console.principal_groups.title') },
        { to: '/access/principals', label: t('console.principals.title') }
      ]}
    />
  )
}

export function PrincipalsListPage() {
  const { t } = useTranslation()
  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions())
  const localIdentity = useLocalIdentityProvider()
  const [query, setQuery] = useState('')
  const deferredQuery = useDeferredValue(query)
  const searchQuery = effectiveResourceSearchQuery(query, deferredQuery)
  const rows = (principals.data?.principals ?? []).filter(principal =>
    matchesResourceSearch(searchQuery, principal.uid, principal.display_name, principal.type, principal.status)
  )

  return (
    <ResourceListPage
      title={t('console.principals.title')}
      description={t('console.principals.description')}
      createTo={localIdentity.enabled ? 'new' : undefined}
      createLabel={localIdentity.enabled ? t('console.principals.new_user') : undefined}
      columns={[
        t('console.principals.principal'),
        t('console.principals.uid'),
        t('console.principals.type'),
        t('console.principals.status')
      ]}
      isLoading={principals.isLoading}
      isEmpty={rows.length === 0}
      emptyTitle={t('console.principals.empty_title')}
      emptyIcon={<RiKey2Line aria-hidden />}
      emptyDescription={t('console.principals.empty_description')}
      error={principals.error}
      isFiltered={Boolean(query.trim())}
      onClearFilters={() => setQuery('')}
      count={rows.length}
      subNav={<AccessSubNav />}
      toolbar={
        <ResourceSearch
          label={t('console.principals.search')}
          placeholder={t('console.principals.search_placeholder')}
          value={query}
          onChange={setQuery}
        />
      }>
      {rows.map(principal => (
        <TableRow key={principal.uid}>
          <TableCell>
            <Link
              className="flex items-center gap-2 text-foreground hover:text-link hover:underline"
              to={encodeURIComponent(principal.uid)}>
              <PrincipalAvatar principal={principal} />
              <span className="truncate">{principal.display_name ?? principal.uid}</span>
            </Link>
          </TableCell>
          <TableCell className="font-mono text-xs">{principal.uid}</TableCell>
          <TableCell>
            <Badge variant="secondary">{t(`console.principals.type_${principal.type}`)}</Badge>
          </TableCell>
          <TableCell>
            <StatusIndicator tone={principal.status === 'active' ? 'positive' : 'neutral'}>
              {t(`console.status.${principal.status}`)}
            </StatusIndicator>
          </TableCell>
          <RowViewAction
            label={t('common.view_details_for', { name: principal.display_name ?? principal.uid })}
            to={encodeURIComponent(principal.uid)}
          />
        </TableRow>
      ))}
    </ResourceListPage>
  )
}

export function PrincipalDetailPage() {
  const { t } = useTranslation()
  const params = useParams()
  const uid = params.uid ?? ''
  const principal = useQuery(ankoleWebPrincipalControllerShowOptions({ path: { uid } }))
  const localIdentity = useLocalIdentityProvider()
  const loadedPrincipal = principal.data?.principal

  return (
    <PageStack className="mx-auto max-w-4xl">
      <div className="grid gap-3">
        <BackLink to="/access/principals" />
        <div className="flex flex-wrap items-center gap-4 border-b border-border pb-5">
          {loadedPrincipal ? <PrincipalAvatar principal={loadedPrincipal} size="lg" /> : null}
          <div className="grid min-w-0 gap-1">
            <h2 className="truncate text-2xl font-semibold tracking-normal text-foreground">
              {loadedPrincipal?.display_name ?? uid}
            </h2>
            <p className="truncate font-mono text-xs text-muted-foreground">{uid}</p>
            {loadedPrincipal?.email ? (
              <p className="truncate text-sm text-muted-foreground">{loadedPrincipal.email}</p>
            ) : null}
          </div>
          {loadedPrincipal ? (
            <div className="flex items-center gap-2">
              <Badge variant="secondary">{t(`console.principals.type_${loadedPrincipal.type}`)}</Badge>
              <StatusIndicator tone={loadedPrincipal.status === 'active' ? 'positive' : 'neutral'}>
                {t(`console.status.${loadedPrincipal.status}`)}
              </StatusIndicator>
            </div>
          ) : null}
          {loadedPrincipal && localIdentity.enabled && loadedPrincipal.type === 'human' ? (
            <Link className={cn(buttonVariants({ size: 'sm', variant: 'outline' }), 'ml-auto')} to="edit">
              {t('console.principals.edit_profile')}
            </Link>
          ) : null}
        </div>
      </div>
      <ErrorBlock error={principal.error} />
      {loadedPrincipal ? (
        <div className="grid gap-10">
          {localIdentity.enabled && loadedPrincipal.type === 'human' ? (
            <LocalPasswordSection principal={loadedPrincipal} />
          ) : null}
          <PrincipalGroupsSection principal={loadedPrincipal} />
          <PrincipalGrantsSection principal={loadedPrincipal} />
        </div>
      ) : principal.isLoading ? (
        <div className="grid gap-2">
          <Skeleton className="h-8 w-full" />
          <Skeleton className="h-8 w-4/5" />
          <Skeleton className="h-8 w-2/3" />
        </div>
      ) : null}
    </PageStack>
  )
}

/** Static operator-domain groups this principal belongs to, with join/leave. */
function PrincipalGroupsSection({ principal }: { principal: PrincipalItem }) {
  const { t } = useTranslation()
  const queryClient = useQueryClient()
  const groups = useQuery(ankoleWebPrincipalControllerGroupsOptions({ path: { uid: principal.uid } }))
  const allGroups = useQuery(ankoleWebAuthZGroupControllerIndexOptions())
  const memberships = groups.data?.principal_groups ?? []

  const addMember = useMutation({
    ...ankoleWebAuthZGroupControllerAddMemberMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.principals.group_added', { id: variables.path.name }))
      void queryClient.invalidateQueries()
    },
    onError: error => toast.error(requestErrorMessage(error))
  })
  const removeMember = useMutation({
    ...ankoleWebAuthZGroupControllerRemoveMemberMutation(),
    onSuccess: (_data, variables) => {
      toast.success(t('console.principals.group_removed', { id: variables.path.name }))
      void queryClient.invalidateQueries()
    },
    // The server refuses removing the last admin member (409); toast its reason.
    onError: error => toast.error(requestErrorMessage(error))
  })

  return (
    <section className="grid gap-4">
      <div className="grid gap-1">
        <h3 className="text-lg font-semibold tracking-normal">{t('console.principals.groups_section_title')}</h3>
        <p className="max-w-2xl text-sm leading-6 text-muted-foreground">
          {t('console.principals.groups_section_description')}
        </p>
      </div>
      <AddMembershipPicker
        ariaLabel={t('console.principals.add_to_group')}
        placeholder={t('console.principals.add_to_group_placeholder')}
        emptyText={t('console.principals.add_to_group_empty')}
        // Only operator-domain static groups accept manual membership.
        candidates={(allGroups.data?.principal_groups ?? [])
          .filter(group => group.domain === 'operator' && group.kind === 'static')
          .map(group => ({ id: group.name, label: principalGroupDisplayName(t, group) }))}
        excludedIDs={new Set(memberships.map(group => group.name))}
        error={allGroups.error}
        isLoading={allGroups.isLoading}
        pending={addMember.isPending}
        onAdd={name => addMember.mutate({ path: { name, principal_uid: principal.uid } })}
      />
      <ErrorBlock error={groups.error} />
      {!groups.error && !groups.isLoading && memberships.length === 0 ? (
        <p className="border border-border bg-card p-6 text-sm text-muted-foreground">
          {t('console.principals.groups_empty')}
        </p>
      ) : !groups.error ? (
        <div className="overflow-x-auto border border-border bg-card">
          <Table className="min-w-[560px]" aria-busy={groups.isLoading}>
            <TableHeader>
              <TableRow>
                <TableHead>{t('console.principals.group')}</TableHead>
                <TableHead>{t('console.principals.kind')}</TableHead>
                <TableHead className="w-0 text-right">
                  <span className="sr-only">{t('console.actions')}</span>
                </TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {groups.isLoading ? (
                <TableRow>
                  <TableCell colSpan={3}>
                    <div className="grid gap-2">
                      <Skeleton className="h-6 w-full" />
                      <Skeleton className="h-6 w-4/5" />
                    </div>
                  </TableCell>
                </TableRow>
              ) : (
                memberships.map(group => {
                  const canRemove = group.domain === 'operator' && group.kind === 'static'
                  return (
                    <TableRow key={group.id}>
                      <TableCell>
                        <Link
                          className="font-mono text-xs text-foreground hover:text-link hover:underline"
                          to={`/access/groups/${encodeURIComponent(group.name)}`}>
                          {group.name}
                        </Link>
                        <span className="ml-2 text-sm text-muted-foreground">
                          {principalGroupDisplayName(t, group)}
                        </span>
                      </TableCell>
                      <TableCell>
                        <div className="flex flex-wrap items-center gap-1">
                          <Badge variant="secondary">{t(`console.principal_groups.kind_${group.kind}`)}</Badge>
                          {group.built_in ? (
                            <Badge variant="info">{t('console.principal_groups.built_in')}</Badge>
                          ) : null}
                        </div>
                      </TableCell>
                      <TableCell className="w-12 text-right">
                        {canRemove ? (
                          <ConfirmDeleteButton
                            pending={removeMember.isPending}
                            confirm={{
                              title: t('console.principals.remove_group_title'),
                              description: t('console.principals.remove_group_description', { id: group.name }),
                              confirmLabel: t('console.principals.remove_group')
                            }}
                            onConfirm={() =>
                              removeMember.mutate({ path: { name: group.name, principal_uid: principal.uid } })
                            }
                          />
                        ) : null}
                      </TableCell>
                    </TableRow>
                  )
                })
              )}
            </TableBody>
          </Table>
        </div>
      ) : null}
    </section>
  )
}

/** Direct grants attached to this principal. */
function PrincipalGrantsSection({ principal }: { principal: PrincipalItem }) {
  const { t } = useTranslation()
  const grants = useQuery(ankoleWebPrincipalControllerGrantsOptions({ path: { uid: principal.uid } }))

  return (
    <PermissionGrantsSection
      title={t('console.principals.grants_section_title')}
      description={t('console.principals.grants_section_description')}
      addLabel={t('console.principals.add_grant')}
      addTo={`/access/principals/${encodeURIComponent(principal.uid)}/grants/new`}
      empty={t('console.principals.grants_empty')}
      error={grants.error}
      grants={grants.data?.permission_grants ?? []}
      isLoading={grants.isLoading}
    />
  )
}

function PrincipalAvatar({ principal, size = 'sm' }: { principal: PrincipalItem; size?: 'sm' | 'lg' }) {
  return (
    <Avatar size={size}>
      {principal.avatar_url ? <AvatarImage src={principal.avatar_url} alt="" /> : null}
      <AvatarFallback>{(principal.display_name ?? principal.uid).slice(0, 1).toUpperCase()}</AvatarFallback>
    </Avatar>
  )
}
