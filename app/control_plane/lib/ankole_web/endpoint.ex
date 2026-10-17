defmodule AnkoleWeb.Endpoint do
  alias Plug.RequestId, as: RequestID

  @moduledoc """
  Phoenix endpoint for the control-plane web process.

  The endpoint keeps the standard Phoenix request pipeline, but session storage
  is delegated to `AnkoleWeb.SessionCookieStore` so cookie sealing uses the
  shared Ankole kernel crypto format.
  """

  use Phoenix.Endpoint, otp_app: :ankole

  # The session payload is stored in the cookie and sealed with Ankole Kernel
  # AEAD. The browser carries the payload but cannot read or tamper with it.
  # `key_context` is threaded down to SessionCookieStore so the cookie's key is
  # derived under a named context, isolating it from other Kernel-derived keys.
  # `secure` is a compile-time flag (off by default for local HTTP dev, on in
  # production behind TLS) — it must be a literal here, so it cannot be runtime-tuned.
  @session_options [
    store: AnkoleWeb.SessionCookieStore,
    key:
      if(Application.compile_env(:ankole, :secure_cookies, false),
        do: "__Host-ankole",
        else: "_ankole_key"
      ),
    key_context: "_ankole_key",
    same_site: "Lax",
    max_age: 86_400,
    http_only: true,
    secure: Application.compile_env(:ankole, :secure_cookies, false)
  ]

  # An OIDC callback URL must carry the scheme the browser used. This trusts
  # `x-forwarded-proto` from every caller. SaaS also uses the ingress-supplied
  # client IP for email protection. The ingress must remove incoming forwarded
  # headers, set its own values, and be the only public path to this process.
  plug AnkoleWeb.Plugs.ResetTenant

  plug Plug.RewriteOn,
       if(Application.compile_env(:ankole, :edition) == :saas,
         do: [:x_forwarded_proto, :x_forwarded_for],
         else: [:x_forwarded_proto]
       )

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

  plug RequestID
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]
  plug AnkoleWeb.WorkerFileRelay
  plug AnkoleWeb.Plugs.RequestHost

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
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :ankole
  end

  plug AnkoleWeb.Plugs.WebhookCallbackBodyReader

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
  plug Plug.Session, @session_options
  plug AnkoleWeb.SiteAdminConsole
  plug Application.compile_env(:ankole, :http_entry, AnkoleWeb.Router)
end
