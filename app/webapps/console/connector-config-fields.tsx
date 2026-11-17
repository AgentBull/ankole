import type { ComponentProps } from 'react'
import { ConnectorConfigFields as Fields } from '../common/connector-config-fields'
import { ErrorBlock } from '../common/error-block'
import { useQuery } from './tenant-context'
import {
  listConnectorAuthConfigsOptions,
  listConnectorCatalogOptions
} from './api/v2/generated/@tanstack/react-query.gen'

export function ConnectorConfigFields(
  props: Omit<ComponentProps<typeof Fields>, 'catalog' | 'connections' | 'loading'>
) {
  const catalog = useQuery(listConnectorCatalogOptions())
  const connections = useQuery(listConnectorAuthConfigsOptions())
  return (
    <>
      <ErrorBlock error={catalog.error ?? connections.error} />
      <Fields
        {...props}
        loading={catalog.isPending || connections.isPending}
        catalog={catalog.data?.connectors}
        connections={connections.data?.connections ?? []}
      />
    </>
  )
}
