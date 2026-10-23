import { principalLabel } from './state/principal-label'
import type { ConsoleActorRef } from './api/generated/types.gen'
import { useQuery } from '@tanstack/react-query'
import { ankoleWebPrincipalControllerShowOptions } from './api/generated/@tanstack/react-query.gen'
import { listTenantsOptions } from './api/v2-site/generated/@tanstack/react-query.gen'
import { fromDocument } from './api/json-api'

/** Attribution uses the author's tenant even when the resource belongs elsewhere. */
export function ActorLabel({ actor }: { actor?: ConsoleActorRef | null }) {
  const tenants = useQuery({
    ...listTenantsOptions(),
    select: document => fromDocument(document),
    enabled: Boolean(actor)
  })
  const author = useQuery({
    ...ankoleWebPrincipalControllerShowOptions({
      path: { uid: actor?.uid ?? '' },
      headers: { 'x-ankole-tenant': actor?.tenant_id ?? '' }
    }),
    enabled: Boolean(actor),
    retry: false
  })
  const tenant = tenants.data?.find(item => item.id === actor?.tenant_id)
  const principal = author.data?.principal
  const label = tenant && principal ? `${tenant.display_name} / ${principalLabel(principal)}` : (actor?.uid ?? '—')

  return <span title={actor ? `${actor.tenant_id} / ${actor.uid}` : undefined}>{label}</span>
}
