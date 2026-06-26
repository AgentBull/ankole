# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ankole,
  ecto_repos: [Ankole.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :ankole, AnkoleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AnkoleWeb.ErrorHTML, json: AnkoleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ankole.PubSub

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use the local Torque adapter for JSON parsing in Phoenix
config :phoenix, :json_library, Ankole.JSON

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

config :ankole, Oban,
  repo: Ankole.Repo,
  queues: [default: 10],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Ankole.ActorRuntime.Jobs.EnqueueDailySessionResets},
       {"*/15 * * * *", Ankole.SignalsGateway.Jobs.CleanupExpiredState}
     ]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
