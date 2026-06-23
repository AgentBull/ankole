import { Button } from '@ankole/uikit/components/button'
import { Card, CardContent, CardHeader, CardTitle } from '@ankole/uikit/components/card'
import { Helmet } from 'react-helmet-async'
import { createBrowserRouter } from 'react-router'
import { useTranslation } from 'react-i18next'

export type SpaKind = 'auth' | 'console' | 'setup'

export type SpaDescriptor = {
  basename: string
  eyebrow: string
  kind: SpaKind
}

/** Creates the temporary router shell used until each SPA has real screens. */
export function createPlaceholderRouter(descriptor: SpaDescriptor) {
  return createBrowserRouter(
    [
      {
        path: '/',
        element: <PlaceholderPage descriptor={descriptor} />
      },
      {
        path: '*',
        element: <PlaceholderPage descriptor={descriptor} />
      }
    ],
    { basename: descriptor.basename }
  )
}

function PlaceholderPage({ descriptor }: { descriptor: SpaDescriptor }) {
  const { t } = useTranslation()
  const title = t(`${descriptor.kind}.title`)
  const description = t(`${descriptor.kind}.description`)

  return (
    <>
      <Helmet>
        <title>{title} | Ankole</title>
      </Helmet>
      <main className="min-h-screen bg-background px-6 py-8 text-foreground">
        <section className="mx-auto grid w-full max-w-5xl gap-6">
          <header className="flex flex-wrap items-end justify-between gap-4">
            <div className="min-w-0">
              <p className="text-xs font-semibold uppercase text-muted-foreground">{descriptor.eyebrow}</p>
              <h1 className="mt-2 text-3xl font-normal leading-tight">{title}</h1>
              <p className="mt-2 max-w-2xl text-sm leading-6 text-muted-foreground">{description}</p>
            </div>
            <div className="flex items-center gap-3">
              <span className="border border-border px-3 py-1 text-xs text-muted-foreground">{t('common.ready')}</span>
              <Button>{t('common.placeholder')}</Button>
            </div>
          </header>

          <Card>
            <CardHeader>
              <CardTitle>{title}</CardTitle>
            </CardHeader>
            <CardContent>
              <div className="grid gap-3 md:grid-cols-3">
                <div className="border border-border bg-card/70 p-4">
                  <strong className="block text-sm">Router</strong>
                  <span className="mt-2 block text-sm leading-6 text-muted-foreground">
                    Browser routing is scoped to {descriptor.basename}.
                  </span>
                </div>
                <div className="border border-border bg-card/70 p-4">
                  <strong className="block text-sm">Query</strong>
                  <span className="mt-2 block text-sm leading-6 text-muted-foreground">
                    TanStack Query is available through the shared provider.
                  </span>
                </div>
                <div className="border border-border bg-card/70 p-4">
                  <strong className="block text-sm">Head</strong>
                  <span className="mt-2 block text-sm leading-6 text-muted-foreground">
                    Document metadata is owned by React Helmet inside the SPA.
                  </span>
                </div>
              </div>
            </CardContent>
          </Card>
        </section>
      </main>
    </>
  )
}
