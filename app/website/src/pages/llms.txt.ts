import type { APIRoute } from 'astro'
import { getCollection } from 'astro:content'
import { DEFAULT_LOCALE } from '../i18n/config'
import { requireSite } from '../lib/docs-markdown'
import { llmsIndex } from '../lib/llms-txt'

/** The conventional root location serves the default-locale index, which links the other locales. */
export const GET: APIRoute = async ({ site }) =>
  new Response(llmsIndex(await getCollection('docs'), DEFAULT_LOCALE, requireSite(site)), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' }
  })
