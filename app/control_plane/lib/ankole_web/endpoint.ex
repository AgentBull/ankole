defmodule AnkoleWeb.Endpoint do
  alias Plug.RequestId, as: RequestID

  @moduledoc """
  Phoenix endpoint for the control-plane web process.

  The endpoint keeps the standard Phoenix request pipeline, but session storage
  is delegated to `AnkoleWeb.SessionCookieStore` so cookie sealing uses the
  shared Ankole kernel crypto format.
  """

  use Phoenix.Endpoint, otp_app: :ankole

  @http_entry Application.compile_env(:ankole, :http_entry, AnkoleWeb.Router)
  @rewrite_on Application.compile_env(:ankole, :http_rewrite_on, [:x_forwarded_proto])
  @static_cors_headers [
    {"access-control-allow-origin", "*"},
    {"timing-allow-origin", "*"}
  ]

  # The session payload is stored in the cookie and sealed with Ankole Kernel
  # AEAD. The browser carries the payload but cannot read or tamper with it.
  # `key_context` is threaded down to SessionCookieStore so the cookie's key is
  # derived under a named context, isolating it from other Kernel-derived keys.

  # An OIDC callback URL must carry the scheme the browser used. This trusts
  # `x-forwarded-proto` from every caller. Deployments that also trust the client
  # IP can add `:x_forwarded_for` to `:http_rewrite_on` at build time. Their ingress
  # must remove incoming forwarded headers, set its own values, and be the only
  # public path to this process.
  plug :reset_tenant
  plug :internal_health

  plug Plug.RewriteOn, @rewrite_on

  # One WebSocket per Agent Computer Worker. The worker auth key arrives as
  # the Phoenix auth token; binary frames carry protobuf envelopes and one
  # frame is bounded so a Worker cannot grow this process without limit.
  socket "/runtime-fabric/worker", AnkoleWeb.RuntimeFabricSocket,
    auth_token: true,
    websocket: [
      connect_info: [:uri],
      max_frame_size: 16 * 1024 * 1024,
      timeout: 60_000,
      compress: false
    ],
    longpoll: false

  socket "/pod/socket", AnkoleWeb.PodSocket,
    websocket: [
      check_origin: {__MODULE__, :check_pod_socket_origin?, []},
      connect_info: [:uri, :peer_data, :x_headers],
      max_frame_size: Ankole.Pod.DocumentWire.max_bytes(),
      timeout: 60_000
    ],
    longpoll: false

  plug RequestID
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug :static_host_admission
  plug :worker_file_relay
  plug :connector_runtime
  plug :drive_vfs
  plug :request_host

  plug Plug.Static,
    at: "/assets",
    from: {AnkoleWeb.Assets, :directory, []},
    gzip: not code_reloading?,
    headers: @static_cors_headers,
    cache_control_for_etags:
      if(code_reloading?, do: "public, no-cache", else: "public, max-age=31536000, immutable")

  plug Plug.Static,
    at: "/fonts/office",
    from: {AnkoleWeb.OfficeFonts, :directory, []},
    only: ~w(manifest.json THIRD-PARTY-NOTICES.txt),
    gzip: not code_reloading?,
    headers: @static_cors_headers,
    cache_control_for_etags:
      if(code_reloading?, do: "public, no-cache", else: "public, max-age=300")

  plug Plug.Static,
    at: "/fonts/office",
    from: {AnkoleWeb.OfficeFonts, :directory, []},
    gzip: not code_reloading?,
    headers: @static_cors_headers,
    cache_control_for_etags:
      if(code_reloading?, do: "public, no-cache", else: "public, max-age=31536000, immutable")

  plug Plug.Static,
    at: "/",
    from: :ankole,
    gzip: not code_reloading?,
    headers: @static_cors_headers,
    only: AnkoleWeb.static_paths() -- ["assets"],
    raise_on_missing_only: code_reloading?

  plug :halt_static_host

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug :webhook_callback_body
  plug :applet_route_body
  plug :drive_upload_body

  plug Plug.Parsers,
    parsers: [
      :urlencoded,
      {:multipart, length: 128 * 1024 * 1024},
      {:json, length: 128 * 1024 * 1024}
    ],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {AnkoleWeb.Plugs.ProviderWebhookBodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head
  plug :session_cookies
  plug :site_admin_console
  plug :dispatch_http_entry

  def client_ip(address, headers) do
    conn = Plug.RewriteOn.call(%Plug.Conn{remote_ip: address, req_headers: headers}, @rewrite_on)
    conn.remote_ip
  end

  def check_pod_socket_origin?(uri), do: AnkoleWeb.PodSocket.check_origin?(uri)

  # Keep business plug implementations out of the endpoint's compile dependencies.
  # Standard library plugs keep their normal compile-time initialization.
  defp reset_tenant(conn, opts),
    do: AnkoleWeb.Plugs.ResetTenant.call(conn, AnkoleWeb.Plugs.ResetTenant.init(opts))

  defp internal_health(conn, _opts), do: AnkoleWeb.EndpointDrain.call_health_plug(conn)

  # Hosts classified as static by the selected host policy serve only static files;
  # root `/` and all dynamic or internal endpoints return 404.
  defp static_host_admission(conn, _opts) do
    {conn, classification} = AnkoleWeb.Plugs.RequestHost.classify_conn(conn)

    if classification == {:ok, :static} do
      if conn.method in ["GET", "HEAD"] and static_request_path?(conn.path_info) do
        Plug.Conn.assign(conn, :host_context, :static)
      else
        send_static_not_found(conn)
      end
    else
      conn
    end
  end

  defp static_request_path?(["assets", _ | _]), do: true
  defp static_request_path?(["fonts", _ | _]), do: true
  defp static_request_path?(["images", _ | _]), do: true
  defp static_request_path?(["favicon.ico"]), do: true
  defp static_request_path?(["robots.txt"]), do: true
  defp static_request_path?(_), do: false

  defp halt_static_host(%Plug.Conn{assigns: %{host_context: :static}} = conn, _opts),
    do: send_static_not_found(conn)

  defp halt_static_host(conn, _opts), do: conn

  defp send_static_not_found(conn) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.put_resp_header("cache-control", "no-store")
    |> Plug.Conn.send_resp(404, "Not found")
    |> Plug.Conn.halt()
  end

  defp worker_file_relay(%Plug.Conn{assigns: %{host_context: :static}} = conn, _opts), do: conn

  defp worker_file_relay(conn, opts),
    do: AnkoleWeb.WorkerFileRelay.call(conn, AnkoleWeb.WorkerFileRelay.init(opts))

  # Runtime credentials bind the tenant. These requests reach the issuing node's
  # internal origin independently of browser host admission, like file relays.
  defp connector_runtime(%Plug.Conn{assigns: %{host_context: :static}} = conn, _opts), do: conn

  defp connector_runtime(
         %Plug.Conn{path_info: ["api", "internal", namespace | _]} = conn,
         _opts
       )
       when namespace in ["mcp", "connectors"] do
    parsers =
      Plug.Parsers.init(
        parsers: [{:json, length: 128 * 1024 * 1024}],
        json_decoder: Phoenix.json_library()
      )

    conn
    |> Plug.Parsers.call(parsers)
    |> AnkoleWeb.Router.call(AnkoleWeb.Router.init([]))
    |> Plug.Conn.halt()
  end

  defp connector_runtime(conn, _opts), do: conn

  defp drive_vfs(%Plug.Conn{assigns: %{host_context: :static}} = conn, _opts), do: conn

  defp drive_vfs(conn, opts),
    do: AnkoleWeb.Plugs.VfsWebdav.call(conn, AnkoleWeb.Plugs.VfsWebdav.init(opts))

  defp request_host(conn, opts),
    do: AnkoleWeb.Plugs.RequestHost.call(conn, AnkoleWeb.Plugs.RequestHost.init(opts))

  defp webhook_callback_body(conn, opts),
    do:
      AnkoleWeb.Plugs.WebhookCallbackBodyReader.call(
        conn,
        AnkoleWeb.Plugs.WebhookCallbackBodyReader.init(opts)
      )

  defp applet_route_body(conn, opts),
    do: AnkoleWeb.Plugs.AppletRouteBody.call(conn, AnkoleWeb.Plugs.AppletRouteBody.init(opts))

  # Plug streams multipart file parts to temporary files. Only Drive byte
  # endpoints use the object backend's bound; JSON and other uploads keep
  # their existing limits. Controllers still enforce the exact file size.
  defp drive_upload_body(%Plug.Conn{method: "POST", path_info: path} = conn, _opts) do
    drive_upload? =
      case path do
        ["api", "v2", "drive", _tenant, "uploads"] -> true
        ["api", "v2", "pod", "pages", _id, "files"] -> true
        ["api", "v2", "pod", "file-pages"] -> true
        ["api", "v2", "pod", "attachments"] -> true
        _ -> false
      end

    if drive_upload? do
      with {:ok, limit} <- Ankole.Files.upload_limit() do
        options =
          Plug.Parsers.init(parsers: [{:multipart, length: limit + 1024 * 1024}], pass: ["*/*"])

        Plug.Parsers.call(conn, options)
      else
        _ -> conn
      end
    else
      conn
    end
  end

  defp drive_upload_body(conn, _opts), do: conn

  defp session_cookies(conn, opts),
    do: AnkoleWeb.SessionCookies.call(conn, AnkoleWeb.SessionCookies.init(opts))

  defp site_admin_console(conn, opts),
    do: AnkoleWeb.SiteAdminConsole.call(conn, AnkoleWeb.SiteAdminConsole.init(opts))

  defp dispatch_http_entry(conn, opts), do: @http_entry.call(conn, @http_entry.init(opts))
end
