import type { APIRoute } from 'astro'
import { getCollection } from 'astro:content'
import { LOCALES, type Locale } from '../../i18n/config'
import { requireSite } from '../../lib/docs-markdown'
import { llmsFull } from '../../lib/llms-txt'

export function getStaticPaths() {
  return LOCALES.map(lang => ({ params: { lang } }))
}

export const GET: APIRoute = async ({ params, site }) =>
  new Response(llmsFull(await getCollection('docs'), params.lang as Locale, requireSite(site)), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' }
  })
