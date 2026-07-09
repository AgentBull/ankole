import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :ankole, Ankole.Repo,
  url: Ankole.Config.Bootstrap.env!("DATABASE_URL"),
  database: "ankole_test#{Ankole.Config.Bootstrap.env_string("MIX_TEST_PARTITION")}",
  template: "template0",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ankole, AnkoleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

config :ankole, AnkoleWeb.Assets, dev_server: "http://assets.test"

config :ankole, Ankole.AIAgent.Library, source_cache_ttl_ms: 0

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :ankole, Oban, testing: :manual, plugins: false, queues: false

config :ankole, :identity_provider_startup_sync, enabled: false
config :ankole, :identity_provider_realtime_reconcile, on_save: false

config :ankole, :runtime_events, enabled: false
