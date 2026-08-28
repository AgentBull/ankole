import { beforeAll, describe, expect, test } from 'bun:test'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { renderToStaticMarkup } from 'react-dom/server'
import { loadLocale } from '../common/i18n'
import { MemoryRouter, Route, Routes } from 'react-router'
import { RowActions, RowViewAction, SubNav } from './console-list-page'
import { brainObjectPath } from './pages/brain/brain-nav'
import { BrainObjectDrawer } from './pages/brain/objects'

// Catalogs load on demand; these assertions render translated en-US copy.
beforeAll(() => loadLocale('en-US'))

describe('SubNav', () => {
  test('gives sibling resource links a named navigation landmark', () => {
    const html = renderToStaticMarkup(
      <MemoryRouter>
        <SubNav
          ariaLabel="Access sections"
          items={[
            { to: '/access/groups', label: 'Groups' },
            { to: '/access/principals', label: 'Principals' }
          ]}
        />
      </MemoryRouter>
    )

    expect(html).toContain('<nav aria-label="Access sections"')
  })
})

describe('RowActions', () => {
  test('keeps a reversible row action beside edit in the row menu', () => {
    const html = renderToStaticMarkup(
      <MemoryRouter>
        <table>
          <tbody>
            <tr>
              <RowActions
                actions={[{ label: 'Enable', onAction: () => {} }]}
                editLabel="Edit"
                editTo="/resources/one"
              />
            </tr>
          </tbody>
        </table>
      </MemoryRouter>
    )

    expect(html).toContain('aria-label="More actions"')
    expect(html).not.toContain('aria-label="Edit"')
  })
})

describe('RowViewAction', () => {
  test('uses the same compact trailing control for routes and local detail views', () => {
    const linkHTML = renderToStaticMarkup(
      <MemoryRouter>
        <table>
          <tbody>
            <tr>
              <RowViewAction label="View resource details" to="/resources/one" />
            </tr>
          </tbody>
        </table>
      </MemoryRouter>
    )
    const buttonHTML = renderToStaticMarkup(
      <table>
        <tbody>
          <tr>
            <RowViewAction label="View resource details" onOpen={() => {}} />
          </tr>
        </tbody>
      </table>
    )

    expect(linkHTML).toContain('aria-label="View resource details"')
    expect(linkHTML).toContain('href="/resources/one"')
    expect(linkHTML).toContain('size-9')
    expect(buttonHTML).toContain('aria-label="View resource details"')
    expect(buttonHTML).toContain('size-9')
  })
})

describe('BrainObjectDrawer', () => {
  test('accepts a decoded Unicode slug with a bare percent sign', () => {
    const render = () =>
      renderToStaticMarkup(
        <QueryClientProvider client={new QueryClient()}>
          <MemoryRouter initialEntries={[brainObjectPath('concepts/增长20%')]}>
            <Routes>
              <Route element={<BrainObjectDrawer />} path="/brain/objects/*" />
            </Routes>
          </MemoryRouter>
        </QueryClientProvider>
      )

    expect(render).not.toThrow()
  })
})
