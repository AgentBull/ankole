import { defineCollection } from 'astro:content'
import { glob } from 'astro/loaders'
import { z } from 'astro/zod'

const docs = defineCollection({
  loader: glob({
    base: './src/content/docs',
    pattern: '**/*.md(*|x)',
    // Entries live at <slug>/<locale>.md; keep the exact path as id (the default slugifies and
    // lowercases locale names like zh-Hans-CN).
    generateId: ({ entry }) => entry.replace(/\.mdx?$/, '')
  }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    section: z.string(),
    order: z.number()
  })
})

export const collections = { docs }
