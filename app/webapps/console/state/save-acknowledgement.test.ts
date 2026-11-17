import { expect, test } from 'bun:test'
import { WorkerEnvEditorModel } from './worker-env-editor-model'
import { WorkerProviderEditorModel } from './worker-provider-editor-model'
import { TenantEditorModel } from './tenant-editor-model'
import { TokenQuotaEditorModel } from './token-quota-editor-model'

test('a Worker provider save confirms only its sent config and credentials', () => {
  const model = new WorkerProviderEditorModel()
  const original = { providerID: 'cloud', kind: 'cloudflare', config: 'before', displayName: 'Cloud', isDefault: false }
  model.initialize('cloud', original)
  model.config.value = 'sent'
  model.setCredential('token', 'sent-token')
  const confirm = model.captureSave()
  model.config.value = 'next'
  model.setCredential('token', 'next-token')
  model.setCredential('added', 'new')
  expect(confirm({ ...original, config: 'sent' })).toBe(true)
  expect(model.config.value).toBe('next')
  expect(model.credentials.value).toEqual({ token: 'next-token', added: 'new' })
  expect(model.dirty.value).toBe(true)
  model[Symbol.dispose]()
})

test('a tenant save does not confirm a name entered after submission', () => {
  const model = new TenantEditorModel()
  const original = { slug: 'team', displayName: 'sent', brainPacks: [] }
  model.initialize('team', original)
  const confirm = model.captureSave()
  model.displayName.value = 'next'
  expect(confirm(original)).toBe(true)
  expect(model.displayName.value).toBe('next')
  expect(model.dirty.value).toBe(true)
  model[Symbol.dispose]()
})

test('a quota save or reset does not erase a limit entered after the request starts', () => {
  const model = new TokenQuotaEditorModel()
  const original = { periodDays: '30', periodStartAt: '2026-10-19T00:00', limitTokens: '100' }
  model.initialize('agent', original)
  const confirm = model.captureSave()
  model.limitTokens.value = '200'
  expect(confirm({ ...original, periodStartAt: '2026-10-20T00:00' })).toBe(true)
  expect(model.periodStartAt.value).toBe('2026-10-20T00:00')
  expect(model.limitTokens.value).toBe('200')
  expect(model.dirty.value).toBe(true)
  model[Symbol.dispose]()
})

test('a secret reveal cannot replace an edited value or a reopened draft', () => {
  const model = new WorkerEnvEditorModel()
  const original = { name: 'SECRET', value: 'masked', secret: true, description: '' }
  model.initialize('SECRET', original)
  const reveal = model.captureReveal()
  model.setValue('replacement')
  expect(reveal('old secret')).toBe(false)
  expect(model.value.value).toBe('replacement')
  const newer = model.captureReveal()
  model.resetSource()
  model.initialize('SECRET', original)
  expect(newer('old secret')).toBe(false)
  const current = model.captureReveal()
  expect(current('current secret')).toBe(true)
  expect(model.dirty.value).toBe(false)
  model[Symbol.dispose]()
})

test('a worker environment save preserves replacement text and invalidates an earlier reveal', () => {
  const model = new WorkerEnvEditorModel()
  const original = { name: 'SECRET', value: 'masked', secret: true, description: '' }
  model.initialize('SECRET', original)
  model.setValue('sent')
  const reveal = model.captureReveal()
  const confirm = model.captureSave()
  model.setValue('next')
  expect(confirm(original)).toBe(true)
  expect(model.value.value).toBe('next')
  expect(model.dirty.value).toBe(true)
  expect(reveal('previous secret')).toBe(false)
  model[Symbol.dispose]()
})
