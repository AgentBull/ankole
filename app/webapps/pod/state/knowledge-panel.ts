import { z } from 'zod'

const optionalText = z.string().nullish()
const panel = z.object({
  backlinks: z.array(
    z.object({
      page_id: z.string(),
      title: z.string(),
      link_type: z.string(),
      context: optionalText
    })
  ),
  claims: z.array(
    z.object({
      id: z.string(),
      claim_type: z.string(),
      claim: z.string(),
      context: optionalText,
      confidence: z.number().nullish(),
      since_date: optionalText,
      provenance: optionalText,
      source_node_id: optionalText
    })
  ),
  timelines: z.array(
    z.object({
      id: z.string(),
      date: z.string(),
      summary: z.string(),
      detail: optionalText,
      provenance: optionalText,
      source_node_id: optionalText
    })
  ),
  scorecard: z.object({ takes: z.number(), brier: z.number().nullable() })
})

/** Validate the fields this view consumes; business names and extra response fields stay open. */
export const parseKnowledgePanel = (value: unknown) => panel.parse(value)
