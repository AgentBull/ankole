defmodule AnkoleWeb.SiteAdminConsole do
  @moduledoc "Runtime mount point for the authenticated site administration shell."
  @behaviour Plug

  @route ["site-admin-console"]
  @default_path "/site-admin-console"

  @host_policy Application.compile_env(:ankole, :host_policy)
  @protocol_roots ~w(api oauth sessions setup internal runtime-fabric dev meta .well-known)

  def path do
    if dedicated_host?(),
      do: "/",
      else: Application.get_env(:ankole, :site_admin_console_path, @default_path)
  end

  def origin(conn), do: dedicated_origin() || AnkoleWeb.PodURL.site_origin(conn)
  def url(conn, path \\ nil), do: origin(conn) <> (path || path())

  defp dedicated_host? do
    @host_policy && Code.ensure_loaded?(@host_policy) &&
      function_exported?(@host_policy, :site_admin_console_origin, 0)
  end

  defp dedicated_origin do
    if dedicated_host?(), do: apply(@host_policy, :site_admin_console_origin, [])
  end

  def validate! do
    configured = path()

    if configured == "/" and dedicated_host?() do
      :ok
    else
      validate_path!(configured)
    end
  end

  defp validate_path!(configured) do
    unless is_binary(configured) and
             Regex.match?(~r/\A\/[A-Za-z0-9._~-]+(?:\/[A-Za-z0-9._~-]+)*\z/, configured) and
             Enum.all?(String.split(configured, "/", trim: true), &(&1 not in [".", ".."])) do
      raise ArgumentError,
            "ANKOLE_SITE_ADMIN_CONSOLE_PATH must be an absolute path without a trailing slash"
    end

    [first | _] = String.split(configured, "/", trim: true)

    occupied =
      [AnkoleWeb.Router, Application.get_env(:ankole, :http_entry, AnkoleWeb.Router)]
      |> Enum.uniq()
      |> Enum.flat_map(& &1.__routes__())
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
    case dedicated_origin() do
      nil -> rewrite_mount(conn)
      origin -> rewrite_host(conn, URI.parse(origin).host)
    end
  end

  defp rewrite_host(conn, host) do
    cond do
      List.first(conn.path_info) in @route ->
        raise Phoenix.Router.NoRouteError, conn: conn, router: AnkoleWeb.Router

      String.downcase(conn.host) == host and not protocol_path?(conn.path_info) ->
        %{conn | path_info: @route ++ conn.path_info}

      true ->
        conn
    end
  end

  # The Console's Signals and Webhooks pages share their first segment with inbound
  # protocol endpoints, which always continue below a version or handler segment.
  defp protocol_path?(["signals", "v1" | _]), do: true
  defp protocol_path?(["webhooks", _ | _]), do: true
  defp protocol_path?([root | _]), do: root in @protocol_roots
  defp protocol_path?([]), do: false

  defp rewrite_mount(conn) do
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
