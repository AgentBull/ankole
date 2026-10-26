import { afterAll, expect, test } from 'bun:test'
import { OpenFeatureProvider } from '@openfeature/react-sdk'
import { OpenFeature } from '@openfeature/web-sdk'
import { renderToStaticMarkup } from 'react-dom/server'
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
