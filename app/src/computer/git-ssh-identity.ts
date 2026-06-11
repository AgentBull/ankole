import { aeadDecrypt, aeadEncrypt, deriveKey, genericHash } from '@agentbull/bullx-native-addons'
import { eq, sql } from 'drizzle-orm'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { z } from 'zod'
import { DB, jsonbParam } from '@/common/database'
import { AppConfigure, ConfigureKeyType } from '@/common/db-schema/app-configure'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'
import { AppEnv } from '@/config/env'

const COMPUTER_GIT_SSH_IDENTITY_KEY = 'computer.git_ssh_identity.v1'
const COMPUTER_GIT_SSH_IDENTITY_KDF_CONTEXT = 'v1'
const SSH_KEY_COMMENT = 'bullx-computer-git@agentbull'

const sealedGitSshIdentitySchema = z.object({
  version: z.literal(1),
  publicKeyOpenSsh: z.string().startsWith('ssh-ed25519 '),
  publicKeyBlake3: z.string().min(1),
  sealed: z.string().min(1)
})

export const ComputerGitSshIdentityConfig = defineAppConfig({
  key: COMPUTER_GIT_SSH_IDENTITY_KEY,
  encrypted: false,
  schema: sealedGitSshIdentitySchema,
  description: 'Sealed SSH identity for BullX computer workers to access GitHub'
})

registerAppConfigDefinitions([ComputerGitSshIdentityConfig])

const gitSshIdentityMaterialSchema = z.object({
  version: z.literal(1),
  generatedAt: z.string().min(1),
  privateKeyOpenSsh: z.string().startsWith('-----BEGIN OPENSSH PRIVATE KEY-----'),
  publicKeyOpenSsh: z.string().startsWith('ssh-ed25519 ')
})

export type ComputerGitSshIdentityMaterial = z.infer<typeof gitSshIdentityMaterialSchema>
export type SealedComputerGitSshIdentity = z.infer<typeof sealedGitSshIdentitySchema>

export async function ensureComputerGitSshIdentity(): Promise<ComputerGitSshIdentityMaterial> {
  return DB.transaction(async tx => {
    await tx.execute(sql`select pg_advisory_xact_lock(hashtext('computer-git-ssh-identity:v1'))`)
    const [row] = await tx
      .select({ value: AppConfigure.value })
      .from(AppConfigure)
      .where(eq(AppConfigure.key, COMPUTER_GIT_SSH_IDENTITY_KEY))
      .limit(1)
    if (row) return unsealComputerGitSshIdentity(sealedGitSshIdentitySchema.parse(row.value.value))

    const material = await generateComputerGitSshIdentityMaterial()
    const storedValue = {
      type: ConfigureKeyType.PLAINTEXT,
      value: sealComputerGitSshIdentity(material)
    }
    await tx.insert(AppConfigure).values({
      key: COMPUTER_GIT_SSH_IDENTITY_KEY,
      value: jsonbParam(storedValue)
    })
    return material
  })
}

export function sealComputerGitSshIdentity(
  material: ComputerGitSshIdentityMaterial,
  token: string = AppEnv.BULLX_COMPUTER_TOKEN
): SealedComputerGitSshIdentity {
  const parsed = gitSshIdentityMaterialSchema.parse(material)
  return {
    version: 1,
    publicKeyOpenSsh: parsed.publicKeyOpenSsh,
    publicKeyBlake3: genericHash(parsed.publicKeyOpenSsh),
    sealed: aeadEncrypt(JSON.stringify(parsed), computerGitSshIdentityKey(token))
  }
}

export function unsealComputerGitSshIdentity(
  value: SealedComputerGitSshIdentity,
  token: string = AppEnv.BULLX_COMPUTER_TOKEN
): ComputerGitSshIdentityMaterial {
  try {
    const plainText = aeadDecrypt(value.sealed, computerGitSshIdentityKey(token)).toString('utf-8')
    const material = gitSshIdentityMaterialSchema.parse(JSON.parse(plainText))
    if (material.publicKeyOpenSsh !== value.publicKeyOpenSsh) {
      throw new Error('public key mismatch')
    }
    return material
  } catch (error) {
    throw new Error('failed to unseal computer Git SSH identity with BULLX_COMPUTER_TOKEN', { cause: error })
  }
}

export async function generateComputerGitSshIdentityMaterial(): Promise<ComputerGitSshIdentityMaterial> {
  const dir = await mkdtemp(join(tmpdir(), 'bullx-computer-git-ssh-'))
  const privateKeyPath = join(dir, 'id_ed25519')
  try {
    const proc = Bun.spawn(
      ['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-C', SSH_KEY_COMMENT, '-f', privateKeyPath],
      {
        stdout: 'pipe',
        stderr: 'pipe'
      }
    )
    const [exitCode, stderr] = await Promise.all([proc.exited, new Response(proc.stderr).text()])
    if (exitCode !== 0) {
      throw new Error(`ssh-keygen failed with exit code ${exitCode}: ${stderr.trim()}`)
    }
    return gitSshIdentityMaterialSchema.parse({
      version: 1,
      generatedAt: new Date().toISOString(),
      privateKeyOpenSsh: await readFile(privateKeyPath, 'utf-8'),
      publicKeyOpenSsh: await readFile(`${privateKeyPath}.pub`, 'utf-8')
    })
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

function computerGitSshIdentityKey(token: string): string {
  return deriveKey(token, 'computer_git_ssh_identity', COMPUTER_GIT_SSH_IDENTITY_KDF_CONTEXT)
}
