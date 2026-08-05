import { describe, expect, test } from 'bun:test'
import { Input } from '@ankole/uikit'
import { renderToStaticMarkup } from 'react-dom/server'
import { MemoryRouter } from 'react-router'
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

  test('gives configuration-heavy editors the workspace width', () => {
    const html = renderToStaticMarkup(
      <MemoryRouter>
        <ResourceEditorPage backTo="/resources" contentWidth="wide" onSubmit={() => {}} title="Edit resource">
          <Input value="" readOnly />
        </ResourceEditorPage>
      </MemoryRouter>
    )

    expect(html).toContain('max-w-6xl')
  })
})
