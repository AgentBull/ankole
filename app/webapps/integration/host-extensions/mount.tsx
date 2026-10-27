import { lazy } from 'react'
import { useBooleanFlagValue } from '@openfeature/react-sdk'
import { InMemoryProvider, OpenFeature } from '@openfeature/web-sdk'
import { mountApp } from '../../common/mount'
import { PodSlotsContext } from '../../pod/slots'
import { PodSettings } from '../../pod/pod-settings'
import { AuthSlotsContext } from '../../auth/slots'
import { EmailOtpForm } from '../../auth/email-otp-form'
import { SlotGate } from '../../common/slots'
import '@ankole/uikit/styles.css'
import '../../common/styles.css'

const PodModule = lazy(() => import('./pod-module'))
const Challenge = lazy(() => import('./auth-challenge'))
const auth = new URLSearchParams(window.location.search).has('auth')
function Conformance() {
  const provider = OpenFeature.getProvider()
  if (!(provider instanceof InMemoryProvider)) throw new Error('The fixture requires the host InMemoryProvider')
  const enabled = useBooleanFlagValue('fixture.visible', false)
  const pluginId = new URLSearchParams(window.location.search).has('inactive') ? 'fixture-inactive' : 'fixture-ui'
  return (
    <>
      <SlotGate slot={{ pluginId }}>
        {enabled => enabled && <span data-testid="ungated-slot">Unconditional slot</span>}
      </SlotGate>
      <button
        type="button"
        onClick={() =>
          provider.putConfiguration({
            'fixture.visible': {
              variants: { on: true, off: false },
              defaultVariant: enabled ? 'off' : 'on',
              disabled: false
            }
          })
        }>
        Toggle fixture feature
      </button>
      {auth ? (
        <AuthSlotsContext value={{ emailOtpChallenge: { pluginId, when: 'fixture.visible', Component: Challenge } }}>
          <EmailOtpForm />
        </AuthSlotsContext>
      ) : (
        <PodSlotsContext
          value={{
            settingsTabs: [
              {
                id: 'fixture-settings',
                pluginId,
                labelKey: 'Fixture settings',
                when: 'fixture.visible',
                Component: PodModule
              }
            ]
          }}>
          <PodSettings />
        </PodSlotsContext>
      )}
    </>
  )
}

await mountApp(<Conformance />)
