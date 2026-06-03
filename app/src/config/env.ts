import { deriveKey } from '@agentbull/bullx-native-addons'
import { z } from 'zod'

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  HTTP_PORT: z.coerce.number().int().positive().default(3000),
  BULLX_SECRET_BASE: z.string().min(16),
  REDIS_URL: z.string().min(1),
  DATABASE_URL: z.string().min(1)
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
