import { describe, expect, it } from 'bun:test'
import { isBlockedIpAddress, sniffImageMedia } from '../../index.js'

describe('isBlockedIpAddress', () => {
  it('blocks private, loopback, link-local, CGNAT, and reserved ranges', () => {
    for (const ip of [
      '0.0.0.0',
      '0.255.1.1',
      '10.1.2.3',
      '100.64.0.1',
      '100.127.255.255',
      '127.0.0.1',
      '169.254.10.10',
      '172.16.0.1',
      '172.31.255.255',
      '192.168.1.1',
      '198.18.0.1',
      '240.0.0.1',
      '::',
      '::1',
      'fc00::1',
      'fd12:3456::1',
      'fe80::1',
      '::ffff:10.0.0.1',
      '::ffff:127.0.0.1',
      '64:ff9b::a00:1'
    ]) {
      expect(isBlockedIpAddress(ip)).toBe(true)
    }
  })

  it('allows public addresses', () => {
    for (const ip of ['1.1.1.1', '8.8.8.8', '100.63.255.255', '172.32.0.1', '2606:4700:4700::1111']) {
      expect(isBlockedIpAddress(ip)).toBe(false)
    }
  })

  it('blocks unparseable input', () => {
    expect(isBlockedIpAddress('not-an-ip')).toBe(true)
  })
})

describe('sniffImageMedia', () => {
  it('detects png/jpeg/gif/webp magic bytes', () => {
    const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0])
    expect(sniffImageMedia(png)).toEqual({ mimeType: 'image/png', defaultExt: '.png' })
    const jpg = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0])
    expect(sniffImageMedia(jpg)).toEqual({ mimeType: 'image/jpeg', defaultExt: '.jpg' })
    const gif = Buffer.from('GIF89a\0\0\0\0\0\0', 'ascii')
    expect(sniffImageMedia(gif)).toEqual({ mimeType: 'image/gif', defaultExt: '.gif' })
    const webp = Buffer.concat([Buffer.from('RIFF'), Buffer.from([0, 0, 0, 0]), Buffer.from('WEBPVP8 ')])
    expect(sniffImageMedia(webp)).toEqual({ mimeType: 'image/webp', defaultExt: '.webp' })
  })

  it('returns null for non-image bytes', () => {
    expect(sniffImageMedia(Buffer.from('plain text here'))).toBeNull()
    expect(sniffImageMedia(Buffer.from('%PDF-1.7 ...'))).toBeNull()
  })
})
