import { aeadDecrypt, aeadEncrypt, deriveKey, generateMtlsBundle } from '@agentbull/bullx-native-addons'
import { eq, sql } from 'drizzle-orm'
import { z } from 'zod'
import { DB, jsonbParam } from '@/common/database'
import { AppConfigure, ConfigureKeyType } from '@/common/db-schema/app-configure'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'
import { AppEnv } from '@/config/env'

const COMPUTER_TLS_BUNDLE_KEY = 'computer.tls.bundle.v1'
const COMPUTER_TLS_BUNDLE_KDF_CONTEXT = 'v1'
const CERT_VALID_DAYS = 3650

const sealedTlsBundleSchema = z.object({
  version: z.literal(1),
  sealed: z.string().min(1)
})

export const ComputerTlsBundleConfig = defineAppConfig({
  key: COMPUTER_TLS_BUNDLE_KEY,
  encrypted: false,
  schema: sealedTlsBundleSchema,
  description: 'Sealed mTLS certificate bundle for BullX computer workers'
})

registerAppConfigDefinitions([ComputerTlsBundleConfig])

const tlsMaterialSchema = z.object({
  version: z.literal(1),
  generatedAt: z.string().min(1),
  caCertPem: z.string().min(1),
  appCertPem: z.string().min(1),
  appKeyPem: z.string().min(1),
  workerCertPem: z.string().min(1),
  workerKeyPem: z.string().min(1),
  workerDnsNames: z.array(z.string().min(1)),
  workerIpAddresses: z.array(z.string().min(1))
})

export type ComputerTlsMaterial = z.infer<typeof tlsMaterialSchema>

export interface ComputerClientTlsConfig {
  caCert: string
  cert: string
  key: string
}

export async function ensureComputerTlsBundle(): Promise<ComputerTlsMaterial> {
  return DB.transaction(async tx => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtext('computer-tls-bundle:v1'))`)
    const [row] = await tx
      .select({ value: AppConfigure.value })
      .from(AppConfigure)
      .where(eq(AppConfigure.key, COMPUTER_TLS_BUNDLE_KEY))
      .limit(1)
    if (row) return unsealComputerTlsBundle(sealedTlsBundleSchema.parse(row.value.value))

    const material = generateComputerTlsMaterial()
    const storedValue = {
      type: ConfigureKeyType.PLAINTEXT,
      value: sealComputerTlsBundle(material)
    }
    await tx.insert(AppConfigure).values({
      key: COMPUTER_TLS_BUNDLE_KEY,
      value: jsonbParam(storedValue)
    })
    return material
  })
}

export async function getComputerClientTlsConfig(): Promise<ComputerClientTlsConfig> {
  const material = await ensureComputerTlsBundle()
  return {
    caCert: material.caCertPem,
    cert: material.appCertPem,
    key: material.appKeyPem
  }
}

export function sealComputerTlsBundle(
  material: ComputerTlsMaterial,
  token: string = AppEnv.BULLX_COMPUTER_TOKEN
): z.infer<typeof sealedTlsBundleSchema> {
  const parsed = tlsMaterialSchema.parse(material)
  return {
    version: 1,
    sealed: aeadEncrypt(JSON.stringify(parsed), computerTlsBundleKey(token))
  }
}

export function unsealComputerTlsBundle(
  value: z.infer<typeof sealedTlsBundleSchema>,
  token: string = AppEnv.BULLX_COMPUTER_TOKEN
): ComputerTlsMaterial {
  try {
    const plainText = aeadDecrypt(value.sealed, computerTlsBundleKey(token)).toString('utf-8')
    return tlsMaterialSchema.parse(JSON.parse(plainText))
  } catch (error) {
    throw new Error('failed to unseal computer TLS bundle with BULLX_COMPUTER_TOKEN', { cause: error })
  }
}

function computerTlsBundleKey(token: string): string {
  return deriveKey(token, 'computer_tls_bundle', COMPUTER_TLS_BUNDLE_KDF_CONTEXT)
}

/** Certificate generation lives in the native addon (rcgen); this stays IO + policy. */
function generateComputerTlsMaterial(): ComputerTlsMaterial {
  const workerDnsNames = computerWorkerDnsNames()
  const workerIpAddresses = computerWorkerIpAddresses()
  const bundle = generateMtlsBundle(workerDnsNames, workerIpAddresses, CERT_VALID_DAYS)
  return {
    version: 1,
    generatedAt: new Date().toISOString(),
    caCertPem: bundle.caCertPem,
    appCertPem: bundle.appCertPem,
    appKeyPem: bundle.appKeyPem,
    workerCertPem: bundle.workerCertPem,
    workerKeyPem: bundle.workerKeyPem,
    workerDnsNames,
    workerIpAddresses
  }
}

function computerWorkerDnsNames(): string[] {
  const configured = AppEnv.BULLX_COMPUTER_TLS_DNS_NAMES?.split(',')
    .map(name => name.trim())
    .filter(Boolean)
  const names = configured?.length
    ? configured
    : [
        'localhost',
        'bullx-computer',
        '*.bullx-computer',
        '*.bullx-computer.default.svc',
        '*.bullx-computer.default.svc.cluster.local'
      ]
  return [...new Set(names)]
}

function computerWorkerIpAddresses(): string[] {
  const configured = AppEnv.BULLX_COMPUTER_TLS_IP_ADDRESSES?.split(',')
    .map(name => name.trim())
    .filter(Boolean)
  return [...new Set(configured?.length ? configured : ['127.0.0.1', '::1'])]
}
