// @ts-nocheck
import { createProviderExecutedToolFactory, lazySchema, zodSchema } from '@/llm/provider-utils'
import { z } from 'zod/v4'

// https://ai.google.dev/gemini-api/docs/maps-grounding
// https://cloud.google.com/vertex-ai/generative-ai/docs/grounding/grounding-with-google-maps

export const googleMaps = createProviderExecutedToolFactory<{}, {}, {}>({
  id: 'google.google_maps',
  inputSchema: lazySchema(() => zodSchema(z.object({}))),
  outputSchema: lazySchema(() => zodSchema(z.object({})))
})
