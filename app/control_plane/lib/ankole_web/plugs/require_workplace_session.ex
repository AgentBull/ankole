defmodule AnkoleWeb.Plugs.RequireWorkplaceSession do
  @moduledoc "Applies the Workplace shell access gate to its internal API."
  @behaviour Plug

  import Plug.Conn, only: [halt: 1]

  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.Plugs.RequireSiteAdminSession

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, opts) do
    case SetupConfig.completed?() do
      {:ok, true} ->
        RequireSiteAdminSession.call(conn, opts)

      _incomplete ->
        conn
        |> ConsoleErrors.render(401, "unauthorized", "Workplace session required")
        |> halt()
    end
  end
end
