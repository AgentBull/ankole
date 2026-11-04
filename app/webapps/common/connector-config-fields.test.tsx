import { expect, test } from 'bun:test'
import { renderToStaticMarkup } from 'react-dom/server'
import type { ComponentProps } from 'react'
import { ConnectorConfigFields } from './connector-config-fields'

const fields = [
  { path: 'clientID', label: { default: 'OAuth client ID' }, type: 'string', required: true },
  { path: 'clientSecret', label: { default: 'OAuth client secret' }, type: 'string', encrypted: true, required: true },
  { path: 'botToken', label: { default: 'Bot token' }, type: 'string', encrypted: true, required: true },
  { path: 'directorySync', label: { default: 'Directory sync' }, type: 'boolean' }
]

function render(configured: string[]) {
  const connections: ComponentProps<typeof ConnectorConfigFields>['connections'] = [
    {
      id: 'connection',
      plugin_id: 'slack',
      slug: 'workspace',
      display_name: 'Workspace',
      auth_scheme: 'platform_app',
      is_default: true,
      status: 'active',
      configured_credential_fields: configured,
      public_metadata: {},
      inserted_at: '2026-11-04T00:00:00Z',
      updated_at: '2026-11-04T00:00:00Z'
    }
  ]
  return renderToStaticMarkup(
    <ConnectorConfigFields
      pluginId="slack-adapter"
      config={{ authConfigId: 'connection', directorySync: true }}
      fields={fields}
      locale="en-US"
      onChange={() => {}}
      onConnectionChange={() => {}}
      connections={connections}
      catalog={[
        {
          id: 'slack',
          plugin_id: 'slack',
          display_name: 'Slack',
          toolkits: [],
          auth_schemes: ['platform_app', 'identity_app'],
          credential_fields: fields.slice(0, 3).map(field => ({ key: field.path })),
          public_fields: []
        }
      ]}
    />
  )
}

test('reusing a bot connection still asks for its missing identity credentials', () => {
  const html = render(['botToken'])
  expect(html).toContain('OAuth client ID')
  expect(html).toContain('OAuth client secret')
  expect(html).toContain('Directory sync')
  expect(html).not.toContain('Bot token')
})

test('complete shared credentials remain hidden while behavior fields remain editable', () => {
  const html = render(['botToken', 'clientID', 'clientSecret'])
  expect(html).not.toContain('OAuth client ID')
  expect(html).not.toContain('OAuth client secret')
  expect(html).not.toContain('Bot token')
  expect(html).toContain('Directory sync')
})
