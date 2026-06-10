import { describe, expect, it } from 'bun:test'
import type { ComputerTlsMaterial } from './tls-config'
import { loadTestEnvFiles } from '../common/tests/load-test-env'

await loadTestEnvFiles()

const { sealComputerTlsBundle, unsealComputerTlsBundle } = await import('./tls-config')

const material: ComputerTlsMaterial = {
  version: 1,
  generatedAt: '2026-06-10T00:00:00.000Z',
  caCertPem: '-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----\n',
  appCertPem: '-----BEGIN CERTIFICATE-----\nAPP\n-----END CERTIFICATE-----\n',
  appKeyPem: '-----BEGIN PRIVATE KEY-----\nAPP\n-----END PRIVATE KEY-----\n',
  workerCertPem: '-----BEGIN CERTIFICATE-----\nWORKER\n-----END CERTIFICATE-----\n',
  workerKeyPem: '-----BEGIN PRIVATE KEY-----\nWORKER\n-----END PRIVATE KEY-----\n',
  workerDnsNames: ['localhost'],
  workerIpAddresses: ['127.0.0.1']
}

describe('computer TLS bundle sealing', () => {
  it('round-trips with BULLX_COMPUTER_TOKEN-derived key material', () => {
    const sealed = sealComputerTlsBundle(material, 'test-computer-token-1')
    expect(sealed.version).toBe(1)
    expect(sealed.sealed).not.toContain('BEGIN CERTIFICATE')
    expect(unsealComputerTlsBundle(sealed, 'test-computer-token-1')).toEqual(material)
  })

  it('does not unseal with the wrong computer token', () => {
    const sealed = sealComputerTlsBundle(material, 'test-computer-token-1')
    expect(() => unsealComputerTlsBundle(sealed, 'test-computer-token-2')).toThrow(
      'failed to unseal computer TLS bundle'
    )
  })
})

describe('generated mTLS bundle', () => {
  it('completes a real mutual-TLS handshake between worker server and app client', async () => {
    const { generateMtlsBundle } = await import('@agentbull/bullx-native-addons')
    const bundle = generateMtlsBundle(['localhost'], ['127.0.0.1'], 30)

    const server = Bun.serve({
      hostname: '127.0.0.1',
      port: 0,
      tls: {
        cert: bundle.workerCertPem,
        key: bundle.workerKeyPem,
        ca: bundle.caCertPem,
        requestCert: true,
        rejectUnauthorized: true
      },
      fetch: () => new Response('ok')
    })
    try {
      const response = await fetch(`https://localhost:${server.port}/`, {
        tls: {
          ca: bundle.caCertPem,
          cert: bundle.appCertPem,
          key: bundle.appKeyPem
        }
      })
      expect(response.status).toBe(200)
      expect(await response.text()).toBe('ok')
    } finally {
      server.stop(true)
    }
  })
})
