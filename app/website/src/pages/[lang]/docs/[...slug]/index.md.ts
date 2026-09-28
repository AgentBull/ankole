import type { APIRoute } from 'astro'
import { getCollection } from 'astro:content'
import type { Locale } from '../../../../i18n/config'
import { docPageMarkdown, requireSite } from '../../../../lib/docs-markdown'
import { docsRouteParams, localizedEntry } from '../../../../lib/docs-model'

export async function getStaticPaths() {
  return docsRouteParams(await getCollection('docs')).map(params => ({ params }))
}

export const GET: APIRoute = async ({ params, site }) => {
  const locale = params.lang as Locale
  const slug = params.slug as string
  const entry = localizedEntry(await getCollection('docs'), slug, locale)
  if (entry === undefined) return new Response(null, { status: 404 })

  return new Response(docPageMarkdown(entry, { locale, slug, site: requireSite(site) }), {
    headers: { 'Content-Type': 'text/markdown; charset=utf-8' }
  })
}
