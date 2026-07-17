import { describe, expect, test } from 'bun:test'
import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { validateNavigationURL } from '../src/browser/navigation-policy'
import type { BrowserMaterial } from '../src/protocol'

const packageRoot = resolve(import.meta.dir, '..')

function material(navigation: BrowserMaterial['navigation']): BrowserMaterial {
  return {
    protocol_version: 1,
    route_id: 'br_1234567890abcdef',
    data_root: '/tmp/ankole-browser-navigation-test/data',
    artifact_root: '/tmp/ankole-browser-navigation-test/artifacts',
    immutable_fingerprint: 'sha256:test',
    material_generation: 0,
    profile: { mode: 'persistent_user_data_dir' },
    backend: { kind: 'local_chromium', executable: '/bin/true', args: [] },
    navigation,
    idle_ttl_ms: 60_000
  }
}

const filterOn = material({ ssrf_filter: true, allow_file_urls: false })
const filterOff = material({ ssrf_filter: false, allow_file_urls: false })

describe('validateNavigationURL', () => {
  test('host classification matches the shared kernel vectors', async () => {
    const vectorsPath = resolve(packageRoot, '../kernel/test/vectors/web_url_host_classification.json')
    const vectors = JSON.parse(await readFile(vectorsPath, 'utf8')) as {
      addresses: Array<{ input: string; class: 'metadata' | 'private' | 'public' }>
    }
    expect(vectors.addresses.length).toBeGreaterThan(0)

    for (const { input, class: hostClass } of vectors.addresses) {
      const url = input.includes(':') ? `https://[${input}]/` : `https://${input}/`
      if (hostClass === 'metadata') {
        // Cloud credential endpoints are rejected regardless of the filter.
        await expect(validateNavigationURL(url, filterOn)).rejects.toThrow('metadata address')
        await expect(validateNavigationURL(url, filterOff)).rejects.toThrow('metadata address')
      } else if (hostClass === 'private') {
        await expect(validateNavigationURL(url, filterOn)).rejects.toThrow('private address')
        await expect(validateNavigationURL(url, filterOff)).resolves.toBeInstanceOf(URL)
      } else {
        await expect(validateNavigationURL(url, filterOn)).resolves.toBeInstanceOf(URL)
      }
    }
  })

  test('blocks hostnames that resolve to private addresses', async () => {
    await expect(validateNavigationURL('localhost/', filterOn)).rejects.toThrow('private address')
    await expect(validateNavigationURL('localhost/', filterOff)).resolves.toBeInstanceOf(URL)
  })

  test('allows file URLs only when the material opts in', async () => {
    const allowing = material({ ssrf_filter: true, allow_file_urls: true })
    expect((await validateNavigationURL('file:///tmp/page.html', allowing)).protocol).toBe('file:')
    await expect(validateNavigationURL('file:///tmp/page.html', filterOn)).rejects.toThrow(
      'unsupported browser URL protocol: file:'
    )
  })

  test('rejects non-web protocols and invalid URLs', async () => {
    await expect(validateNavigationURL('ftp://example.com/x', filterOn)).rejects.toThrow(
      'unsupported browser URL protocol: ftp:'
    )
    await expect(validateNavigationURL('not a url', filterOn)).rejects.toThrow('invalid URL')
  })

  test('prepends https when the scheme is missing', async () => {
    const url = await validateNavigationURL('8.8.8.8:8443/path', filterOn)
    expect(url.href).toBe('https://8.8.8.8:8443/path')
  })
})
