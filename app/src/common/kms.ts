import { deriveKey } from '@agentbull/bullx-native-addons'
import { AppEnv } from '@/config/env'

export enum SecretKeyPurpose {
  DATABASE_ENCRYPTION = 'database_encryption',
  ADMIN_AUTH_SESSION = 'admin_auth_session'
}

export function getSecretKey(purpose: SecretKeyPurpose, context?: string): string {
  return deriveKey(AppEnv.ROOT_SECRET, purpose, context)
}
