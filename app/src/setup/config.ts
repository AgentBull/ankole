import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'

export const SetupCompletedConfig = defineAppConfig({
  key: 'setup.completed',
  encrypted: false,
  schema: z.boolean(),
  defaultValue: false,
  description: 'Whether the BullX Agent installation setup has completed'
})

export const SetupBootstrapActivationCodeConfig = defineAppConfig({
  key: 'setup.bootstrap_activation_code',
  encrypted: false,
  schema: z.string().regex(/^[A-Z0-9]{8}$/),
  description: 'Current bootstrap activation code for the setup session gate'
})

registerAppConfigDefinitions([SetupCompletedConfig, SetupBootstrapActivationCodeConfig])
