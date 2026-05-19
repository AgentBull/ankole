# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

Code.require_file("support/bootstrap.exs", __DIR__)

config :bullx,
  namespace: BullX,
  ecto_repos: [BullX.Repo],
  generators: [timestamp_type: :utc_datetime],
  runtime_env: config_env()

# Configure the endpoint
config :bullx, BullXWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: BullXWeb.ErrorHTML, json: BullXWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: BullX.PubSub

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :bullx, BullX.Mailer, adapter: Swoosh.Adapters.Local

config :inertia,
  endpoint: BullXWeb.Endpoint,
  static_paths: ["/.rsbuild/manifest.json"],
  default_version: "1",
  history: [encrypt: false],
  ssr: false

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :req_llm, load_dotenv: false

# I18n / Localize bootstrap. `BullX.I18n.Catalog` owns the per-key
# translation dictionaries under `priv/locales/*.toml`; Localize is
# used only for MF2 parsing/formatting and CLDR data. We deliberately
# do NOT pin `:supported_locales` here — Localize's CLDR-backed
# locale resolution stays on its default (all CLDR IDs) so MF2
# formatters can look up number systems, plurals, etc.
config :localize,
  default_locale: :en,
  mf2_functions: %{}

config :bullx, :i18n, locales_dir: "priv/locales"

config :bullx, :installation_timezone, "Etc/UTC"

config :bullx, Oban,
  repo: BullX.Repo,
  queues: [target_sessions: 10],
  plugins: false

config :bullx, :event_bus,
  target_session_idle_tick_ms: 5_000,
  target_session_runtime_retention_seconds: 3_600,
  target_session_cleanup_interval_ms: 60_000,
  stream_retention_seconds: 900,
  max_stream_chunk_bytes: 65_536

config :bullx, :event_bus_targets, ai_agent: BullX.AIAgent

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
