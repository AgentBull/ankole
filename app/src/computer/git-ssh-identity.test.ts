import { describe, expect, it } from 'bun:test'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { generateComputerGitSshIdentityMaterial, sealComputerGitSshIdentity, unsealComputerGitSshIdentity } =
  await import('./git-ssh-identity')

describe('computer Git SSH identity sealing', () => {
  it('round-trips with BULLX_COMPUTER_TOKEN-derived key material', async () => {
    const material = await generateComputerGitSshIdentityMaterial()
    const sealed = sealComputerGitSshIdentity(material, 'test-computer-token-1')
    expect(sealed.version).toBe(1)
    expect(sealed.publicKeyOpenSsh).toStartWith('ssh-ed25519 ')
    expect(sealed.sealed).not.toContain('OPENSSH PRIVATE KEY')
    expect(unsealComputerGitSshIdentity(sealed, 'test-computer-token-1')).toEqual(material)
  })

  it('does not unseal with the wrong computer token', async () => {
    const material = await generateComputerGitSshIdentityMaterial()
    const sealed = sealComputerGitSshIdentity(material, 'test-computer-token-1')
    expect(() => unsealComputerGitSshIdentity(sealed, 'test-computer-token-2')).toThrow(
      'failed to unseal computer Git SSH identity'
    )
  })
})
