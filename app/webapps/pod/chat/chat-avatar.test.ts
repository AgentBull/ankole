import { describe, expect, test } from 'bun:test'
import { avatarInitials } from './chat-avatar'

describe('avatar initials', () => {
  test('take the first and last words of a Latin name', () => {
    expect(avatarInitials('Aleksandra Wiśniewska-Kowalczyk')).toBe('AW')
    expect(avatarInitials('Quarterly Revenue Reconciliation & Variance Analysis Agent')).toBe('QA')
    expect(avatarInitials('Nguyễn Thị Ánh Tuyết')).toBe('NT')
  })

  test('skip a generational suffix', () => {
    expect(avatarInitials('Bartholomew Fitzgerald-Montgomery III')).toBe('BF')
  })

  test('take two letters from a single short name', () => {
    expect(avatarInitials('Jo')).toBe('JO')
    expect(avatarInitials('ops')).toBe('OP')
  })

  test('skip emoji and punctuation', () => {
    expect(avatarInitials('🧾 Finance Close')).toBe('FC')
    expect(avatarInitials('🧑🏽‍💻Dev')).toBe('DE')
    expect(avatarInitials('(Contractor) Lee')).toBe('CL')
  })

  test('use one glyph from a wide script', () => {
    expect(avatarInitials('客户成功周报助手')).toBe('客')
    expect(avatarInitials('김민준')).toBe('김')
  })

  test('fall back when the name has no letters', () => {
    expect(avatarInitials('')).toBe('?')
    expect(avatarInitials('🚀🔥')).toBe('?')
  })
})
