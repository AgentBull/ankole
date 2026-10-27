import { afterAll, expect, test } from 'bun:test'
import { OpenFeatureProvider } from '@openfeature/react-sdk'
import { OpenFeature } from '@openfeature/web-sdk'
import { lazy } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { validateConsoleSlots } from '../../console/slots'
import { initializeFeatures } from '../features'
import { ActivePluginsContext, SlotGate, validateSlotIDs } from './index'

const originalProvider = OpenFeature.getProvider()
afterAll(async () => {
  await OpenFeature.setProviderAndWait(originalProvider)
})

test('slot IDs reject duplicate and built-in claims', () => {
  expect(() => validateSlotIDs([{ id: 'general' }], ['general'])).toThrow('reserved slot ID')
  expect(() => validateSlotIDs([{ id: 'fixture' }, { id: 'fixture' }], [])).toThrow('slot ID')
  expect(() => validateSlotIDs([{ id: 'fixture' }], ['general'])).not.toThrow()
})

test('Console slot declarations reject reserved routes', () => {
  const Fixture = lazy(async () => ({ default: () => null }))
  expect(() =>
    validateConsoleSlots({
      routes: [{ id: 'custom', pluginId: 'saas', path: '/tenants/extra', scope: 'site', Component: Fixture }]
    })
  ).toThrow('Console route path')

  const routes = [
    { id: 'codes', pluginId: 'saas', path: '/invitation-codes', scope: 'site' as const, Component: Fixture },
    { id: 'codes-new', pluginId: 'saas', path: '/invitation-codes/new', scope: 'site' as const, Component: Fixture },
    {
      id: 'codes-edit',
      pluginId: 'saas',
      path: '/invitation-codes/$codeID',
      scope: 'tenant' as const,
      Component: Fixture
    }
  ]
  expect(() => validateConsoleSlots({ routes })).not.toThrow()
})

test('active Plugin slots use the mounted snapshot and official SDK conditions', async () => {
  await initializeFeatures({ 'fixture.off': false, 'fixture.on': true })

  function Fixture({ pluginId, when, label }: { pluginId: string; when?: string; label: string }) {
    return <SlotGate slot={{ pluginId, when }}>{enabled => (enabled ? <span>{label}</span> : null)}</SlotGate>
  }
  const html = renderToStaticMarkup(
    <OpenFeatureProvider>
      <ActivePluginsContext value={['fixture-active']}>
        <Fixture pluginId="fixture-active" when="fixture.on" label="Enabled" />
        <Fixture pluginId="fixture-active" when="fixture.off" label="Disabled" />
        <Fixture pluginId="fixture-active" when="fixture.missing" label="Unknown" />
        <Fixture pluginId="fixture-active" label="Unconditional" />
        <Fixture pluginId="fixture-inactive" when="fixture.on" label="Inactive" />
        <SlotGate>{enabled => (enabled ? <span>Absent</span> : null)}</SlotGate>
      </ActivePluginsContext>
    </OpenFeatureProvider>
  )
  expect(html).toBe('<span>Enabled</span><span>Unconditional</span>')
})
