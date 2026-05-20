// Thin client for the web console JSON API.
//
// Every request rides the session cookie (`credentials: "same-origin"`). A 401
// means the session expired underneath the SPA, so we bounce back to the login
// page with a `return_to` pointing at wherever the user currently is.

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly body: unknown,
  ) {
    super(`Console API request failed (${status})`)
    this.name = "ApiError"
  }
}

export function csrfToken(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
}

export async function apiGet<T>(path: string): Promise<T> {
  const response = await fetch(path, {
    method: "GET",
    credentials: "same-origin",
    headers: { accept: "application/json" },
  })

  if (response.status === 401) {
    redirectToLogin()
    throw new ApiError(401, null)
  }

  if (!response.ok) {
    throw new ApiError(response.status, await safeJson(response))
  }

  return (await response.json()) as T
}

export function redirectToLogin(): void {
  const returnTo = window.location.pathname + window.location.search
  window.location.assign(`/sessions/new?return_to=${encodeURIComponent(returnTo)}`)
}

async function safeJson(response: Response): Promise<unknown> {
  try {
    return await response.json()
  } catch {
    return null
  }
}
