import type { APIRoute } from 'astro'
import { getCollection } from 'astro:content'
import { DEFAULT_LOCALE } from '../i18n/config'
import { requireSite } from '../lib/docs-markdown'
import { llmsFull } from '../lib/llms-txt'

/** The conventional root location serves the default-locale documentation. */
export const GET: APIRoute = async ({ site }) =>
  new Response(llmsFull(await getCollection('docs'), DEFAULT_LOCALE, requireSite(site)), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' }
  })
