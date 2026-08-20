# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

Code.require_file("support/bootstrap.exs", __DIR__)

Ankole.Config.Bootstrap.load_dotenv!(root: Path.expand("..", __DIR__), env: config_env())

config :ankole,
  ecto_repos: [Ankole.Repo],
  generators: [timestamp_type: :utc_datetime]

config :ankole, Ankole.Repo, types: Ankole.PostgrexTypes

config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.ChinaMarketAIProviders,
  Ankole.Plugins.DingTalkAdapter,
  Ankole.Plugins.GoogleWorkspaceAdapter,
  Ankole.Plugins.LarkAdapter,
  Ankole.Plugins.Microsoft365Adapter,
  Ankole.Plugins.SlackAdapter,
  Ankole.Plugins.WeComAdapter
]

# Configure the endpoint
config :ankole, AnkoleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AnkoleWeb.ErrorHTML, json: AnkoleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ankole.PubSub

# Configure Elixir's Logger for Docker/Kubernetes structured-log ingestion.
config :logger, :default_handler,
  formatter:
    {Ankole.Logging.JSONFormatter,
     %{
       environment: Atom.to_string(config_env()),
       labels: %{
         "service" => "ankole-control-plane",
         "component" => "control-plane",
         "runtime" => "beam"
       }
     }}

# Use the local Torque adapter for JSON parsing in Phoenix
config :phoenix, :json_library, Ankole.JSON

config :mime, :types, %{
  "text/event-stream" => ["event-stream"]
}

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

config :ankole, Oban,
  repo: Ankole.Repo,
  queues: [default: 10],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Ankole.SignalsGateway.ActorRuntime.Jobs.EnqueueDailySessionResets},
       {"0 * * * *", Ankole.IdentityProviders.Jobs.EnqueueDirectorySyncs},
       {"*/15 * * * *", Ankole.SignalsGateway.Jobs.CleanupExpiredState},
       {"41 * * * *", Ankole.AIGateway.Jobs.CleanupExpiredArtifacts}
     ]}
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
