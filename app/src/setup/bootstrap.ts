import { appConfigService } from '@/config/app-configure'
import { logger } from '@/common/logger'
import { SetupBootstrapActivationCodeConfig, SetupCompletedConfig } from './config'

const ACTIVATION_CODE_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

export interface SetupBootstrapResult {
  completed: boolean
  activationCode?: string
}

export async function initializeSetupBootstrap(): Promise<SetupBootstrapResult> {
  const completed = (await appConfigService.get(SetupCompletedConfig)) === true
  if (completed) {
    await appConfigService.delete(SetupBootstrapActivationCodeConfig)
    return { completed: true }
  }

  const activationCode = randomActivationCode()
  await appConfigService.set(SetupBootstrapActivationCodeConfig, activationCode)
  logger.info({ activationCode }, 'BullX Agent setup bootstrap activation code reset')

  return {
    completed: false,
    activationCode
  }
}

export function randomActivationCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8))
  let code = ''
  for (const byte of bytes) code += ACTIVATION_CODE_ALPHABET[byte % ACTIVATION_CODE_ALPHABET.length]

  return code
}
