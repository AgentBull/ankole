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
  Ankole.Plugins.DiscordAdapter,
  Ankole.Plugins.GoogleWorkspaceAdapter,
  Ankole.Plugins.LarkAdapter,
  Ankole.Plugins.Microsoft365Adapter,
  Ankole.Plugins.SlackAdapter,
  Ankole.Plugins.TelegramAdapter,
  Ankole.Plugins.WeComAdapter
]

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
       {"* * * * *", Ankole.Brain.Jobs.Tick},
       {"0 * * * *", Ankole.IdentityProviders.Jobs.EnqueueDirectorySyncs},
       {"*/15 * * * *", Ankole.SignalsGateway.Jobs.CleanupExpiredState},
       {"41 * * * *", Ankole.AIGateway.Jobs.CleanupExpiredArtifacts}
     ]}
  ]

import_config "#{config_env()}.exs"
