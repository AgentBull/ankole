import { describe, expect, test } from 'bun:test'
import { preloadTransliteration } from '../../common/tenant-slug'
import { BrainPacksStepModel } from './brain-packs-step-model'

describe('BrainPacksStepModel', () => {
  test('derives a tenant slug and preserves an explicit edit', async () => {
    await preloadTransliteration()
    const model = new BrainPacksStepModel()
    await Promise.resolve()
    model.initialize('setup-brain-packs', [], { displayName: 'Default', slug: 'default' })

    model.companyName.value = '煜马科技'
    expect(model.slug.value).toBe('yumakeji')
    model.companyName.value = 'Acme 公司'
    expect(model.slug.value).toBe('acme-gongsi')
    model.setPackSelected('legal', true)
    model.editSlug(model.slug.value)
    model.customSlug.value = 'acme-legal'
    model.companyName.value = 'Acme Legal'

    expect(model.canSubmit()).toBe(true)
    expect(model.submission()).toEqual({
      packs: ['legal'],
      displayName: 'Acme Legal',
      slug: 'acme-legal'
    })
    model[Symbol.dispose]()
  })

  test('allows continuing without an optional business pack', async () => {
    await preloadTransliteration()
    const model = new BrainPacksStepModel()
    await Promise.resolve()
    model.initialize('setup-brain-packs', [], { displayName: 'Default', slug: 'default' })
    model.companyName.value = 'Acme'

    expect(model.canSubmit()).toBe(true)
    expect(model.submission()).toEqual({ packs: [], displayName: 'Acme', slug: 'acme' })
    model[Symbol.dispose]()
  })

  test('validates the slug and preserves local edits across query refetches', async () => {
    await preloadTransliteration()
    const model = new BrainPacksStepModel()
    await Promise.resolve()
    model.initialize('setup-brain-packs', [], { displayName: 'Default', slug: 'default' })
    model.companyName.value = 'Acme'
    model.setPackSelected('software', true)
    model.initialize('setup-brain-packs', [], { displayName: 'Other', slug: 'other' })

    expect(model.submission()).toEqual({ packs: ['software'], displayName: 'Acme', slug: 'acme' })
    model.editSlug('acme')
    model.customSlug.value = 'bad-'
    expect(model.canSubmit()).toBe(false)
    model.customSlug.value = 'a'
    expect(model.canSubmit()).toBe(true)
    model[Symbol.dispose]()
  })
})
