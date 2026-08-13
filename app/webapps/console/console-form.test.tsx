import { describe, expect, test } from 'bun:test'
import { Input } from '@ankole/uikit'
import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter } from 'react-router'
import { ConfigFields } from '../common/config-fields'
import { LabeledField, ResourceEditorPage } from './console-form'

describe('console forms', () => {
  test('lets application validation handle required fields on editor submit', () => {
    const html = renderToStaticMarkup(
      <MemoryRouter>
        <ResourceEditorPage backTo="/resources" onSubmit={() => {}} title="New resource">
          <LabeledField label="Name" required>
            <Input value="" readOnly />
          </LabeledField>
        </ResourceEditorPage>
      </MemoryRouter>
    )

    expect(html).toContain('<form class="grid gap-6" noValidate=""')
    expect(html).toContain('required=""')
  })

  test('connects an application validation error to its field', () => {
    const html = renderToStaticMarkup(
      <LabeledField label="Name" error="Name is required" required>
        <Input value="" readOnly />
      </LabeledField>
    )

    expect(html).toContain('aria-invalid="true"')
    expect(html).toContain('aria-describedby=')
    expect(html).toContain('Name is required')
  })

  test('connects a disabled field to the reason it is unavailable', () => {
    const html = renderToStaticMarkup(
      <LabeledField label="Context length" description="Select a provider first.">
        <Input disabled value="" readOnly />
      </LabeledField>
    )

    expect(html).toContain('disabled=""')
    expect(html).toContain('aria-describedby=')
    expect(html).toContain('Select a provider first.')
  })

  test('does not duplicate the header back link with a footer cancel action', () => {
    const html = renderToStaticMarkup(
      <MemoryRouter>
        <ResourceEditorPage backTo="/resources" onSubmit={() => {}} title="Edit resource">
          <Input value="Changed value" readOnly />
        </ResourceEditorPage>
      </MemoryRouter>
    )

    expect(html.match(/href="\/resources"/g)).toHaveLength(1)
  })

  test('keeps a stored secret out of the editable input value', () => {
    const html = renderToStaticMarkup(
      <ConfigFields
        config={{}}
        fields={[{ encrypted: true, path: 'botToken', required: true, type: 'secret' }]}
        locale="en-US"
        preservedSecretPaths={['botToken']}
        preservedSecretPlaceholder="Saved — enter a new value to replace"
        onChange={() => {}}
      />
    )

    expect(html).toContain('type="password"')
    expect(html).toContain('autoComplete="new-password"')
    expect(html).toContain('placeholder="Saved — enter a new value to replace"')
    expect(html).toContain('value=""')
    expect(html).not.toContain('required=""')
  })
})
