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
  generators: [timestamp_type: :utc_datetime]

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

config :bullx, Oban,
  repo: BullX.Repo,
  queues: [gateway_signals: 10],
  plugins: false

config :bullx, :gateway,
  mailbox_queues: ["gateway_signals"],
  mailbox_default_queue: "gateway_signals",
  mailbox_dedupe_window_seconds: 86_400,
  router: BullX.Gateway.Router.Unavailable,
  consumer_delivery: BullX.Gateway.ConsumerDelivery.Unavailable

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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
