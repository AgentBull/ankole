import { describe, expect, test } from 'bun:test'
import { OIDCClientEditorModel, emptyDraft, writeBody } from './oidc-client-editor-model'
import { seedEditorDraft } from '../use-editor-draft'

describe('OIDC client session settings', () => {
  test('a refetch cannot replace operator edits, and switching client resets the draft', () => {
    const model = new OIDCClientEditorModel()
    const first = {
      ...emptyDraft(),
      allowedIdentityProviderIDs: ['lark'],
      backchannelLogoutURI: 'https://rp.test/logout'
    }
    seedEditorDraft(model, { resource: 'oidc-client', clientID: 'a' }, first)
    model.setDraft(current => ({ ...current, allowedIdentityProviderIDs: ['local'] }))
    seedEditorDraft(model, { resource: 'oidc-client', clientID: 'a' }, first)
    expect(model.draft.value.allowedIdentityProviderIDs).toEqual(['local'])
    expect(model.dirty.value).toBe(true)
    seedEditorDraft(model, { resource: 'oidc-client', clientID: 'b' }, emptyDraft())
    expect(model.draft.value.backchannelLogoutURI).toBe('')
    expect(model.dirty.value).toBe(false)
    model[Symbol.dispose]()
  })

  test('clearing source and logout fields sends explicit empty values to the server', () => {
    const draft = emptyDraft()
    draft.postLogoutRedirectURIs = ' https://rp.test/signed-out \nhttps://rp.test/exit\n'
    const body = writeBody(draft, {})
    expect(body.allowed_identity_provider_ids).toEqual([])
    expect(body.backchannel_logout_uri).toBe(null)
    expect(body.post_logout_redirect_uris).toEqual(['https://rp.test/signed-out', 'https://rp.test/exit'])
    expect(body.allow_insecure_local_logout).toBe(false)
  })
})
