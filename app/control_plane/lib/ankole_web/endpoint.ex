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
  @rewrite_on if(Application.compile_env(:ankole, :edition) == :saas,
                do: [:x_forwarded_proto, :x_forwarded_for],
                else: [:x_forwarded_proto]
              )

  # The session payload is stored in the cookie and sealed with Ankole Kernel
  # AEAD. The browser carries the payload but cannot read or tamper with it.
  # `key_context` is threaded down to SessionCookieStore so the cookie's key is
  # derived under a named context, isolating it from other Kernel-derived keys.

  # An OIDC callback URL must carry the scheme the browser used. This trusts
  # `x-forwarded-proto` from every caller. SaaS also uses the ingress-supplied
  # client IP. The ingress must remove incoming forwarded
  # headers, set its own values, and be the only public path to this process.
  plug :reset_tenant

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
      check_origin: :conn,
      connect_info: [:uri, :peer_data, :x_headers],
      max_frame_size: Ankole.Pod.DocumentWire.max_bytes(),
      timeout: 60_000
    ],
    longpoll: false

  plug RequestID
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug :worker_file_relay
  plug :request_host

  plug Plug.Static,
    at: "/assets",
    from: {AnkoleWeb.Assets, :directory, []},
    gzip: not code_reloading?

  plug Plug.Static,
    at: "/",
    from: :ankole,
    gzip: not code_reloading?,
    only: AnkoleWeb.static_paths() -- ["assets"],
    raise_on_missing_only: code_reloading?

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug :webhook_callback_body
  plug :applet_route_body

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

  # Keep business plug implementations out of the endpoint's compile dependencies.
  # Standard library plugs keep their normal compile-time initialization.
  defp reset_tenant(conn, opts),
    do: AnkoleWeb.Plugs.ResetTenant.call(conn, AnkoleWeb.Plugs.ResetTenant.init(opts))

  defp worker_file_relay(conn, opts),
    do: AnkoleWeb.WorkerFileRelay.call(conn, AnkoleWeb.WorkerFileRelay.init(opts))

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

  defp session_cookies(conn, opts),
    do: AnkoleWeb.SessionCookies.call(conn, AnkoleWeb.SessionCookies.init(opts))

  defp site_admin_console(conn, opts),
    do: AnkoleWeb.SiteAdminConsole.call(conn, AnkoleWeb.SiteAdminConsole.init(opts))

  defp dispatch_http_entry(conn, opts), do: @http_entry.call(conn, @http_entry.init(opts))
end
