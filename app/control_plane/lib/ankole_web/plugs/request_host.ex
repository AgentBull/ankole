defmodule AnkoleWeb.Plugs.RequestHost do
  @moduledoc "The build-selected Host classification for HTTP and Worker connections."
  @behaviour Plug

  @callback classify(URI.t()) :: {:ok, :site | :public | {:pod, Ecto.UUID.t()}} | :error
  @policy Application.compile_env(:ankole, :host_policy)

  @impl true
  def init(opts), do: opts

  if @policy do
    def classify_uri(uri), do: @policy.classify(uri)

    @impl true
    def call(conn, _opts) do
      case @policy.classify(Plug.Conn.request_url(conn) |> URI.parse()) do
        {:ok, {:pod, tenant_id} = context} ->
          :ok = Ankole.Repo.put_tenant_id(tenant_id)
          Plug.Conn.assign(conn, :host_context, context)

        {:ok, context} when context in [:site, :public] ->
          Plug.Conn.assign(conn, :host_context, context)

        _ ->
          conn |> Plug.Conn.send_resp(400, "Invalid host") |> Plug.Conn.halt()
      end
    end

    def worker_allowed?(uri), do: is_struct(uri, URI) and @policy.classify(uri) == {:ok, :site}
  else
    def classify_uri(uri), do: AnkoleWeb.PodURL.local_host(uri)

    @impl true
    def call(conn, _opts) do
      case AnkoleWeb.PodURL.local_host(Plug.Conn.request_url(conn) |> URI.parse()) do
        {:ok, {:pod, tenant_id} = context} ->
          :ok = Ankole.Repo.put_tenant_id(tenant_id)
          Plug.Conn.assign(conn, :host_context, context)

        {:ok, context} ->
          conn = Plug.Conn.assign(conn, :host_context, context)

          if conn.method == "GET" and conn.host in ["localhost", "127.0.0.1", "::1"] and
               browser_shell?(conn.request_path) and
               URI.parse(AnkoleWeb.PodURL.site_origin(conn)).host != conn.host do
            if Map.has_key?(URI.decode_query(conn.query_string), "flow") do
              conn
              |> Plug.Conn.send_resp(
                401,
                "The sign-in address changed. Open #{AnkoleWeb.PodURL.site_origin(conn)} to sign in again."
              )
              |> Plug.Conn.halt()
            else
              query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

              conn
              |> Phoenix.Controller.redirect(
                external: AnkoleWeb.PodURL.site_origin(conn) <> conn.request_path <> query
              )
              |> Plug.Conn.halt()
            end
          else
            conn
          end

        :error ->
          conn |> Plug.Conn.send_resp(404, "Pod not found") |> Plug.Conn.halt()
      end
    end

    def worker_allowed?(_uri), do: true

    defp browser_shell?(path) do
      console = AnkoleWeb.SiteAdminConsole.path()

      path in ["/", "/setup", "/sessions/new", console] or
        String.starts_with?(path, ["/setup/", console <> "/"])
    end
  end
end
