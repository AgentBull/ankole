import Config

webapps_path = Path.expand("../../webapps", __DIR__)

config :ankole, Ankole.Repo,
  template: "template0",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :ankole, AnkoleWeb.Endpoint,
  # Worker containers reach the development control plane at
  # `host.docker.internal`, which on Linux and in the dev container is the
  # Docker bridge gateway, not the loopback interface. So the endpoint listens
  # on every interface, and other machines on the network can reach it too.
  http: [ip: {0, 0, 0, 0}],
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

# These mounts exist only in the source checkout, never in a release.
internal_skills_root = Path.expand("../../../internals/skills", __DIR__)

config :ankole, Ankole.AgentWorkers,
  source_root: Path.expand("../../agent_computer/src", __DIR__),
  internal_skills_root: if(File.dir?(internal_skills_root), do: internal_skills_root)

# `kit dev` sets ANKOLE_FILES_STORE; this default serves a bare `mix phx.server`.
config :ankole, Ankole.ObjectStore,
  spec: %{scheme: "fs", root: Path.expand("../../../var/ankole-dev/files", __DIR__)}

config :ankole, AnkoleWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      ~r"lib/ankole_web/router\.ex$"E,
      ~r"lib/ankole_web/(controllers|components)/.*\.(ex|eex)$"E
    ]
  ]

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
