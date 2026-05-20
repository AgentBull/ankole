defmodule BullXWeb.WebConsoleHTML do
  @moduledoc """
  Renders the static HTML entry page for the web console SPA.

  The server only ships an empty mount point and the hashed Rsbuild assets for
  the `web-console` entry. Everything after first paint is client-rendered by
  TanStack Router and fetched from the JSON API.
  """

  use BullXWeb, :html

  embed_templates "web_console_html/*"
end
