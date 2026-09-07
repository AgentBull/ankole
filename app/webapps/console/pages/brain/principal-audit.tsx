import { Badge, Table, TableBody, TableCell, TableHead, TableHeader, TableRow, Skeleton } from '@ankole/uikit'
import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router'
import {
  ankoleWebBrainControllerPrincipalKnowledgeOptions,
  ankoleWebPrincipalControllerIndexOptions
} from '../../api/generated/@tanstack/react-query.gen'
import { ErrorBlock } from '../../../common/error-block'
import { LabeledField } from '../../console-form'
import { PageHeader, PageStack } from '../../console-page'
import { formatConsoleDate } from '../../console-primitives'
import { SinglePrincipalPicker } from '../../principal-picker'
import { BrainSubNav, brainObjectPath } from './brain-nav'
import { ClaimStateBadge } from './claims'

/** Audits every claim where one Principal is holder, author, or the audience. */
export function BrainPrincipalAuditPage() {
  const { t } = useTranslation()
  const [principalUID, setPrincipalUID] = useState('')

  const principals = useQuery(ankoleWebPrincipalControllerIndexOptions({ query: { include_disabled: true } }))
  const knowledge = useQuery({
    ...ankoleWebBrainControllerPrincipalKnowledgeOptions({ path: { principal_uid: principalUID } }),
    enabled: Boolean(principalUID)
  })
  const rows = knowledge.data?.claims ?? []

  return (
    <PageStack>
      <PageHeader
        title={t('console.brain.principal_audit_title')}
        description={t('console.brain.principal_audit_description')}
      />
      <BrainSubNav />

      <div className="max-w-md border border-border bg-card p-4">
        <LabeledField label={t('console.brain.audit_principal')}>
          <SinglePrincipalPicker
            ariaLabel={t('console.brain.audit_principal')}
            candidates={(principals.data?.principals ?? []).map(principal => ({
              id: principal.uid,
              label:
                principal.status === 'disabled'
                  ? `${principal.display_name} · ${t('console.status.disabled')}`
                  : principal.display_name
            }))}
            error={principals.error}
            isLoading={principals.isLoading}
            placeholder={t('console.brain.select_principal')}
            value={principalUID}
            onChange={setPrincipalUID}
          />
        </LabeledField>
      </div>

      <ErrorBlock error={knowledge.error} />

      {!principalUID ? (
        <p className="border border-dashed border-border px-4 py-6 text-sm text-muted-foreground">
          {t('console.brain.principal_audit_empty')}
        </p>
      ) : knowledge.isLoading ? (
        <Skeleton className="h-48 w-full" />
      ) : rows.length === 0 ? (
        <p className="border border-dashed border-border px-4 py-6 text-sm text-muted-foreground">
          {t('console.brain.principal_audit_no_claims', { uid: principalUID })}
        </p>
      ) : (
        <Table
          containerClassName="border border-border bg-card"
          containerLabel={t('console.brain.principal_audit_title')}>
          <TableHeader>
            <TableRow>
              <TableHead>{t('console.brain.claim')}</TableHead>
              <TableHead>{t('console.brain.type')}</TableHead>
              <TableHead>{t('console.brain.holder')}</TableHead>
              <TableHead>{t('console.brain.author')}</TableHead>
              <TableHead>{t('console.brain.object')}</TableHead>
              <TableHead>{t('console.brain.scope')}</TableHead>
              <TableHead>{t('console.brain.state')}</TableHead>
              <TableHead>{t('console.brain.created')}</TableHead>
            </TableRow>
          </TableHeader>
          <TableBody>
            {rows.map(claim => (
              <TableRow key={claim.id}>
                <TableCell className="min-w-72 max-w-[380px] whitespace-normal break-words text-sm leading-6">
                  {claim.claim}
                </TableCell>
                <TableCell>
                  <Badge variant={claim.claim_type === 'fact' ? 'secondary' : 'info'}>
                    {t(`console.brain.claim_type_${claim.claim_type}`)}
                    {claim.kind ? ` · ${claim.kind}` : ''}
                  </Badge>
                </TableCell>
                <TableCell className="font-mono text-xs">{claim.holder ?? '—'}</TableCell>
                <TableCell className="font-mono text-xs">{claim.author_uid ?? '—'}</TableCell>
                <TableCell className="font-mono text-xs">
                  {claim.object_slug ? (
                    <Link className="text-link hover:underline" to={brainObjectPath(claim.object_slug)}>
                      {claim.object_slug}
                    </Link>
                  ) : (
                    '—'
                  )}
                </TableCell>
                <TableCell className="font-mono text-xs">{claim.audience_scope}</TableCell>
                <TableCell>
                  <ClaimStateBadge claim={claim} />
                </TableCell>
                <TableCell className="text-xs text-muted-foreground">{formatConsoleDate(claim.created_at)}</TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </PageStack>
  )
}
