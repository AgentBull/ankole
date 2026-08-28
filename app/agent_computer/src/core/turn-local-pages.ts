import { z } from 'zod'

export const TurnLocalPageSchema = z.string().regex(/^page_[1-9]\d*$/)

export function createTurnLocalPageRegistry(subject: string) {
  const cursors = new Map<string, string>()

  return {
    cursorFor(page: string): string {
      const cursor = cursors.get(page)
      if (!cursor) throw new Error(`unknown ${subject} page ${page}; use next_page from this turn`)
      return cursor
    },

    register(cursor: string): string {
      for (const [page, existingCursor] of cursors) {
        if (existingCursor === cursor) return page
      }

      const page = `page_${cursors.size + 1}`
      cursors.set(page, cursor)
      return page
    }
  }
}
