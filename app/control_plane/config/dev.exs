import Config

webapps_path = Path.expand("../../webapps", __DIR__)

config :ankole, Ankole.Repo,
  url: Ankole.Config.Bootstrap.env!("DATABASE_URL"),
  template: "template0",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ankole, AnkoleWeb.Endpoint,
  # Binding to loopback ipv4 address prevents access from other machines.
  # Change to `ip: {0, 0, 0, 0}` to allow access from other machines.
  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  watchers: [
    bun: ["run", "dev", cd: webapps_path]
  ]

config :ankole, AnkoleWeb.Assets, dev_server: "http://127.0.0.1:3035"

# Phoenix reloads controller and route modules in development. Keep the OpenAPI
# operation lookup live as well, or a new route can use a stale operation cache.
config :open_api_spex, :cache_adapter, OpenApiSpex.Plug.NoneCache

config :ankole, Ankole.AIAgent.Library,
  internal_skills_root: Path.expand("../../../internals/skills", __DIR__),
  source_cache_ttl_ms: 0

# Reload browser tabs when matching files change.
config :ankole, AnkoleWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      # Static assets, except user uploads
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      # Router, controllers, and templates
      ~r"lib/ankole_web/router\.ex$"E,
      ~r"lib/ankole_web/(controllers|components)/.*\.(ex|eex)$"E
    ]
  ]

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
