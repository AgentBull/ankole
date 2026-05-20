import { useQuery } from "@tanstack/react-query"
import { apiGet } from "./api"

export type Principal = {
  id: string
  uid: string
  display_name: string | null
  type: "human" | "agent"
  status: "active" | "disabled"
  avatar_url: string | null
}

export const sessionQueryKey = ["console", "session"] as const

export function useSession() {
  return useQuery({
    queryKey: sessionQueryKey,
    queryFn: () => apiGet<{ principal: Principal }>("/console/api/session"),
    select: result => result.principal,
    staleTime: 5 * 60 * 1000,
  })
}

export function principalDisplayName(principal: Principal | undefined): string {
  return principal?.display_name?.trim() || principal?.uid || "Signed in"
}

export function principalInitials(principal: Principal | undefined): string {
  const source = principal?.display_name?.trim() || principal?.uid || "?"
  const parts = source.split(/\s+/).filter(Boolean)
  const letters = parts.length >= 2 ? `${parts[0][0]}${parts[parts.length - 1][0]}` : source.slice(0, 2)
  return letters.toUpperCase()
}
