import { describe, expect, test } from 'bun:test'
import { Input } from '@ankole/uikit'
import { createMemoryHistory, createRootRoute, createRoute, createRouter, RouterProvider } from '@tanstack/react-router'
import type { ReactNode } from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { ConfigFields } from '../common/config-fields'
import { parseRouterSearch, stringifyRouterSearch } from '../common/router'
import { LabeledField, ResourceEditorPage } from './console-form'

async function renderWithRouter(node: ReactNode, initialEntry = '/') {
  const rootRoute = createRootRoute()
  const route = createRoute({
    getParentRoute: () => rootRoute,
    path: '$',
    component: () => node
  })
  const router = createRouter({
    routeTree: rootRoute.addChildren([route]),
    history: createMemoryHistory({ initialEntries: [initialEntry] }),
    parseSearch: parseRouterSearch,
    stringifySearch: stringifyRouterSearch
  })
  await router.load()
  return renderToStaticMarkup(<RouterProvider router={router} />)
}

describe('console forms', () => {
  test('lets application validation handle required fields on editor submit', async () => {
    const html = await renderWithRouter(
      <ResourceEditorPage backTo="/resources" onSubmit={() => {}} title="New resource">
        <LabeledField label="Name" required>
          <Input value="" readOnly />
        </LabeledField>
      </ResourceEditorPage>
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

  test('does not duplicate the header back link with a footer cancel action', async () => {
    const html = await renderWithRouter(
      <ResourceEditorPage backTo="/resources" onSubmit={() => {}} title="Edit resource">
        <Input value="Changed value" readOnly />
      </ResourceEditorPage>
    )

    expect(html.match(/href="\/resources"/g)).toHaveLength(1)
  })

  test('makes a terminal resource read-only without offering a save action', async () => {
    const html = await renderWithRouter(
      <ResourceEditorPage backTo="/resources" readOnly title="Completed resource">
        <Input value="Final value" />
      </ResourceEditorPage>
    )

    expect(html).toContain('<fieldset class="contents" disabled="">')
    expect(html).not.toContain('type="submit"')
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
