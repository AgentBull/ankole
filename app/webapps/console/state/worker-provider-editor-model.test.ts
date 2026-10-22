import { expect, test } from 'bun:test'
import type { WorkerProviderKind } from '../api/generated/types.gen'
import { seedEditorDraft } from '../use-editor-draft'
import { newWorkerProviderDraft, workerProviderDraft, WorkerProviderEditorModel } from './worker-provider-editor-model'

const docker: WorkerProviderKind = {
  kind: 'docker',
  example: '# Keep this comment\ncpus: 2\n',
  credentials: {}
}

test('a provider refetch keeps operator YAML and credential edits, and never seeds a mask as a secret', () => {
  const model = new WorkerProviderEditorModel()
  const provider = {
    provider_id: 'remote',
    display_name: 'Remote',
    kind: 'cloudflare',
    config: '# Operator comment\ninstance: lite\n',
    credentials: { api_token: '********' },
    is_default: false,
    agent_count: 0,
    selectable: true
  }
  const sourceKey = `provider:${provider.provider_id}`
  seedEditorDraft(model, sourceKey, workerProviderDraft(provider), false)
  expect(model.config.value).toBe(provider.config)
  expect(model.credentials.value).toEqual({})
  model.config.value += 'idleReleaseAfter: 5m\n'
  model.setCredential('api_token', 'replacement')
  seedEditorDraft(model, sourceKey, workerProviderDraft({ ...provider, config: 'instance: standard\n' }), false)
  expect(model.config.value).toBe('# Operator comment\ninstance: lite\nidleReleaseAfter: 5m\n')
  expect(model.credentials.value).toEqual({ api_token: 'replacement' })
  expect(model.dirty.value).toBe(true)
  model.captureSave()({
    providerID: model.providerID.value,
    displayName: model.displayName.value,
    kind: model.kind.value,
    config: model.config.value,
    isDefault: model.isDefault.value
  })
  expect(model.credentials.value).toEqual({})
  expect(model.dirty.value).toBe(false)
  model[Symbol.dispose]()
})

test('new provider drafts start from the selected type example and discard credentials when the type changes', () => {
  const model = new WorkerProviderEditorModel()
  seedEditorDraft(model, 'new', newWorkerProviderDraft(docker), false)
  expect(model.config.value).toBe(docker.example)
  model.setCredential('api_token', 'only-for-the-previous-type')
  model.selectKind({ ...docker, kind: 'kubernetes', example: 'namespace: workers\n' })
  expect(model.config.value).toBe('namespace: workers\n')
  expect(model.credentials.value).toEqual({})
  model[Symbol.dispose]()
})

test('a removed stored credential is a null change until the operator keeps the stored value', () => {
  const model = new WorkerProviderEditorModel()
  const provider = {
    provider_id: 'aws',
    display_name: 'AWS',
    kind: 'lambda',
    config: 'region: us-east-1\n',
    credentials: { sessionToken: '********' },
    is_default: false,
    agent_count: 0,
    selectable: true
  }
  seedEditorDraft(model, 'provider:aws', workerProviderDraft(provider), false)
  model.setCredential('sessionToken', null)
  expect(model.credentials.value).toEqual({ sessionToken: null })
  expect(model.dirty.value).toBe(true)
  model.setCredential('sessionToken', '')
  expect(model.dirty.value).toBe(false)
  model[Symbol.dispose]()
})
