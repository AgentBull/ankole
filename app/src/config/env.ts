import { deriveKey } from '@agentbull/bullx-native-addons'
import { z } from 'zod'

const envSchema = z.object({
  BULLX_LOG_LEVEL: z.enum(['trace', 'debug', 'info', 'warn', 'error', 'fatal', 'silent']).optional(),
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  HTTP_PORT: z.coerce.number().int().positive().default(3000),
  BULLX_SECRET_BASE: z.string().min(16),
  REDIS_URL: z.string().min(1),
  DATABASE_URL: z.string().min(1),
  BULLX_DATABASE_POOL_MAX: z.coerce.number().int().positive().default(10),
  // Shared bootstrap secret with the computer worker fleet. It seals the
  // computer mTLS bundle in app-configure without exposing BULLX_SECRET_BASE to
  // workers.
  BULLX_COMPUTER_TOKEN: z.string().min(16),
  BULLX_COMPUTER_TLS_DNS_NAMES: z.string().min(1).optional(),
  BULLX_COMPUTER_TLS_IP_ADDRESSES: z.string().min(1).optional()
})

const parsedEnv = envSchema.parse(Bun.env)

const appConstants = {
  IS_KUBERNETES: Bun.env.KUBERNETES_SERVICE_HOST !== undefined,
  IS_PRODUCTION: parsedEnv.NODE_ENV === 'production',
  IS_DEVELOPMENT: parsedEnv.NODE_ENV === 'development',
  ROOT_SECRET: deriveKey(parsedEnv.BULLX_SECRET_BASE, 'app_root_secret', parsedEnv.NODE_ENV)
}

export type AppEnvSchema = z.infer<typeof envSchema> & typeof appConstants
export const AppEnv = {
  ...parsedEnv,
  ...appConstants
} as AppEnvSchema
