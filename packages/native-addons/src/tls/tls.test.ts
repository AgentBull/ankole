import { describe, expect, it } from 'bun:test'
import { generateMtlsBundle } from '../../index.js'

describe('generateMtlsBundle', () => {
  it('produces a CA plus client/server certificate pairs in PEM', () => {
    const bundle = generateMtlsBundle(['localhost', '*.bullx-computer'], ['127.0.0.1', '::1'], 3650)
    expect(bundle.caCertPem).toStartWith('-----BEGIN CERTIFICATE-----')
    expect(bundle.appCertPem).toStartWith('-----BEGIN CERTIFICATE-----')
    expect(bundle.workerCertPem).toStartWith('-----BEGIN CERTIFICATE-----')
    expect(bundle.appKeyPem).toContain('PRIVATE KEY')
    expect(bundle.workerKeyPem).toContain('PRIVATE KEY')
    // Distinct keys per role.
    expect(bundle.appKeyPem).not.toBe(bundle.workerKeyPem)
  })

  it('rejects malformed IP SANs', () => {
    expect(() => generateMtlsBundle(['localhost'], ['not-an-ip'], 30)).toThrow()
  })
})
