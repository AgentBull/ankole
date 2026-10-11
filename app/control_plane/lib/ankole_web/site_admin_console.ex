defmodule AnkoleWeb.SiteAdminConsole do
  @moduledoc "Runtime mount point for the authenticated site administration shell."
  @behaviour Plug

  @route ["site-admin-console"]
  @default_path "/site-admin-console"

  def path, do: Application.get_env(:ankole, :site_admin_console_path, @default_path)

  def validate! do
    configured = path()

    unless is_binary(configured) and
             Regex.match?(~r/\A\/[A-Za-z0-9._~-]+(?:\/[A-Za-z0-9._~-]+)*\z/, configured) and
             Enum.all?(String.split(configured, "/", trim: true), &(&1 not in [".", ".."])) do
      raise ArgumentError,
            "ANKOLE_SITE_ADMIN_CONSOLE_PATH must be an absolute path without a trailing slash"
    end

    [first | _] = String.split(configured, "/", trim: true)

    occupied =
      AnkoleWeb.Router.__routes__()
      |> Enum.map(&(&1.path |> String.split("/", trim: true) |> List.first()))
      |> Enum.reject(&(&1 in [nil, "site-admin-console"]))
      |> Kernel.++(AnkoleWeb.static_paths())

    if first in occupied do
      raise ArgumentError, "ANKOLE_SITE_ADMIN_CONSOLE_PATH conflicts with an existing route"
    end

    :ok
  end

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    mount = String.split(path(), "/", trim: true)
    decoded = Enum.map(conn.path_info, &URI.decode/1)

    cond do
      Enum.take(decoded, length(mount)) == mount ->
        %{conn | path_info: @route ++ Enum.drop(decoded, length(mount))}

      Enum.take(decoded, length(@route)) == @route ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: AnkoleWeb.Router

      true ->
        conn
    end
  end
end
