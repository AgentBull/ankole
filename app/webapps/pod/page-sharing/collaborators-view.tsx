import { useTranslation } from 'react-i18next'
import { Button, Tabs, TabsContent, TabsList, TabsTrigger, TooltipProvider } from '@ankole/uikit'
import { RiLink, RiUserAddLine } from '@remixicon/react'
import { useSignals } from '@preact/signals-react/runtime'
import type { PageRole, PageSharingDetail } from '../content-api'
import { ContentError } from '../content-primitives'
import { subjectKey, type PageSharingModel, type SharingGrant, type SharingScopeTab } from '../state/page-sharing'
import { CollaboratorRow } from './collaborator-row'
import { SubviewHeader } from './sharing-primitives'
import type { PageSharingMutations } from './use-page-sharing'

export function CollaboratorsView({
  model,
  sharing,
  ordinaryGrants,
  roles,
  canManage,
  mutations,
  copyLink,
  onBack,
  onOpenInvite
}: {
  model: InstanceType<typeof PageSharingModel>
  sharing: PageSharingDetail
  ordinaryGrants: readonly SharingGrant[]
  roles: Partial<Record<PageRole, string>>
  canManage: boolean
  mutations: PageSharingMutations
  copyLink(): Promise<void>
  onBack(): void
  onOpenInvite(scope: SharingScopeTab): void
}) {
  useSignals()
  const { t } = useTranslation()
  const containerGrants = ordinaryGrants.filter(grant => (grant.target_scope ?? 'container') === 'container')
  const selfGrants = ordinaryGrants.filter(grant => grant.target_scope === 'self')
  const containerCount = sharing.inherited.length + containerGrants.length

  return (
    <TooltipProvider>
      <div className="flex min-h-0 flex-col">
        <SubviewHeader title={t('pod.sharing.manage_collaborators')} disabled={mutations.pending} onBack={onBack} />

        <Tabs
          value={model.scopeTab.value}
          onValueChange={next => {
            if (next === 'container' || next === 'self') model.scopeTab.value = next
          }}
          className="min-h-0 flex-1 gap-0">
          <div className="px-4">
            <TabsList variant="default" className="w-full justify-start">
              <TabsTrigger value="container" className="flex-none px-3">
                {t('pod.sharing.tab_container')}
                <span className="text-xs text-muted-foreground tabular-nums">{containerCount}</span>
              </TabsTrigger>
              <TabsTrigger value="self" className="flex-none px-3">
                {t('pod.sharing.tab_self')}
                {selfGrants.length > 0 && (
                  <span className="text-xs text-muted-foreground tabular-nums">{selfGrants.length}</span>
                )}
              </TabsTrigger>
            </TabsList>
          </div>

          <TabsContent value="container" className="max-h-80 overflow-y-auto px-4 py-2.5">
            <p className="pb-1.5 text-xs text-muted-foreground">{t('pod.sharing.all_collaborators_hint')}</p>
            {containerCount === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">{t('pod.sharing.no_collaborators')}</p>
            ) : (
              <ul className="divide-y divide-border/60">
                {sharing.inherited.map((item, idx) => (
                  <CollaboratorRow
                    key={`inherited:${subjectKey(item)}:${idx}`}
                    subject={item}
                    roles={roles}
                    origin={item.origin}
                  />
                ))}
                {containerGrants.map(grant => (
                  <CollaboratorRow
                    key={`container:${subjectKey(grant)}`}
                    subject={grant}
                    roles={roles}
                    editable={canManage}
                    pending={mutations.pending}
                    onChangeRole={role => mutations.changeGrantRole(grant, role, 'container')}
                    onRemove={() => mutations.removeGrant(grant)}
                  />
                ))}
              </ul>
            )}
          </TabsContent>

          <TabsContent value="self" className="max-h-80 overflow-y-auto px-4 py-2.5">
            {selfGrants.length === 0 ? (
              <p className="py-6 text-center text-sm text-muted-foreground">{t('pod.sharing.no_direct_grants')}</p>
            ) : (
              <ul className="divide-y divide-border/60">
                {selfGrants.map(grant => (
                  <CollaboratorRow
                    key={`self:${subjectKey(grant)}`}
                    subject={grant}
                    roles={roles}
                    editable={canManage}
                    pending={mutations.pending}
                    onChangeRole={role => mutations.changeGrantRole(grant, role, 'self')}
                    onRemove={() => mutations.removeGrant(grant)}
                  />
                ))}
              </ul>
            )}
          </TabsContent>
        </Tabs>

        {!!mutations.error && (
          <div className="px-4 pb-2.5">
            <ContentError error={mutations.error} />
          </div>
        )}

        <div className="flex items-center justify-between border-t border-border px-4 py-2.5">
          {canManage ? (
            <Button
              variant="ghost"
              size="sm"
              disabled={mutations.pending}
              onClick={() => onOpenInvite(model.scopeTab.value)}>
              <RiUserAddLine aria-hidden className="size-4" />
              {t('pod.sharing.add_collaborators')}
            </Button>
          ) : (
            <Button variant="outline" size="sm" onClick={() => void copyLink()}>
              <RiLink aria-hidden className="size-4" />
              {t('pod.content.copy_link')}
            </Button>
          )}
        </div>
      </div>
    </TooltipProvider>
  )
}
