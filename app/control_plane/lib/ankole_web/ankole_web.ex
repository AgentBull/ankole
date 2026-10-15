defmodule AnkoleWeb do
  @moduledoc false

  # The only top-level paths served straight from priv/static. Used both by the
  # endpoint's Plug.Static and by verified routes (so `~p` knows these are static
  # files, not router paths). Note there are no LiveView/layout helpers in this
  # module: Phoenix here only renders the thin SPA shell, so the surface is small.
  def static_paths, do: ~w(assets fonts images favicon.ico robots.txt)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
    end
  end

  def channel do
    quote do
      use Phoenix.Channel
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html, :json]

      import Plug.Conn

      unquote(verified_routes())
    end
  end

  def html do
    quote do
      import Phoenix.Template, only: [embed_templates: 1]

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1, view_template: 1]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AnkoleWeb.Endpoint,
        router: AnkoleWeb.Router,
        statics: AnkoleWeb.static_paths()
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
