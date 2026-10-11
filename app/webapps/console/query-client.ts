import { MutationCache } from '@tanstack/react-query'

declare module '@tanstack/react-query' {
  interface Register {
    mutationMeta: {
      /** `false` marks a mutation that changes no data the Console shows. */
      invalidates?: false
    }
  }
}

/** Refresh Console data after success without delaying mutation completion. */
export function createConsoleMutationCache(): MutationCache {
  return new MutationCache({
    onSuccess: (_data, _variables, _context, mutation, { client }) => {
      if (mutation.meta?.invalidates !== false) void client.invalidateQueries()
    }
  })
}
