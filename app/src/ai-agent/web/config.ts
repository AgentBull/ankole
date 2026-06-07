import { z } from 'zod'
import { defineAppConfig, registerAppConfigDefinitions } from '@/config/app-configure'

/**
 * App-config definitions for the built-in web providers. Keys are encrypted and
 * read through `appConfigService.get(...)`. Provider `available()` checks treat
 * a missing key as "unavailable".
 *
 * Preferred-provider keys accept any provider id (built-in or plugin), so they
 * use `z.string()` rather than an enum; routing falls back to availability
 * order when unset. Built-in ids: search = exa|parallel, extract =
 * exa|jina|webfetch.
 */

export const WebExaApiKey = defineAppConfig<string>({
  key: 'ai_agent.web.exa.api_key',
  description: 'Exa API key (web_search + web_extract)',
  encrypted: true,
  schema: z.string().min(1)
})

export const WebParallelApiKey = defineAppConfig<string>({
  key: 'ai_agent.web.parallel.api_key',
  description: 'Parallel.ai API key (web_search)',
  encrypted: true,
  schema: z.string().min(1)
})

export const WebJinaApiKey = defineAppConfig<string>({
  key: 'ai_agent.web.jina.api_key',
  description: 'Jina Reader API key (web_extract); optional — keyless works at a lower rate limit',
  encrypted: true,
  schema: z.string().min(1)
})

export const WebSearchProviderConfig = defineAppConfig<string>({
  key: 'ai_agent.web.search_provider',
  description: 'Preferred web_search provider id; falls back to availability order when unset',
  encrypted: false,
  schema: z.string().min(1)
})

export const WebExtractProviderConfig = defineAppConfig<string>({
  key: 'ai_agent.web.extract_provider',
  description: 'Preferred web_extract provider id; falls back to availability order when unset',
  encrypted: false,
  schema: z.string().min(1)
})

registerAppConfigDefinitions([
  WebExaApiKey,
  WebParallelApiKey,
  WebJinaApiKey,
  WebSearchProviderConfig,
  WebExtractProviderConfig
])
