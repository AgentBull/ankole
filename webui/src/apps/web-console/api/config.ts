// Runtime configuration for the generated hey-api client. Imported once for its
// side effects from main.tsx, before anything issues a request.
//
// The generated client defaults baseUrl to the dev origin; we point it at the
// current origin and ride the session cookie. Mutations carry the CSRF token
// from the page's meta tag (the server's :internal_api pipeline runs
// protect_from_forgery). A 401 means the session lapsed, so we bounce to login.
import { client } from "./client/client.gen"

function csrfToken(): string {
  return document.querySelector<HTMLMetaElement>('meta[name="csrf-token"]')?.content ?? ""
}

client.setConfig({
  baseUrl: window.location.origin,
  credentials: "same-origin",
})

client.interceptors.request.use(request => {
  if (request.method !== "GET" && request.method !== "HEAD") {
    request.headers.set("x-csrf-token", csrfToken())
  }
  return request
})

client.interceptors.response.use(response => {
  if (response.status === 401) {
    const returnTo = window.location.pathname + window.location.search
    window.location.assign(`/sessions/new?return_to=${encodeURIComponent(returnTo)}`)
  }
  return response
})
