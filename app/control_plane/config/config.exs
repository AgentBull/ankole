import Config

config :phoenix, :filter_parameters, [
  "password",
  "newPassword",
  "secret",
  "token",
  "code",
  "state"
]

config :ankole,
  ecto_repos: [Ankole.Repo],
  generators: [timestamp_type: :utc_datetime]

config :ankole, Ankole.Repo, types: Ankole.PostgrexTypes

config :ankole, :control_plane_plugin_modules, [
  Ankole.Plugins.ChinaMarketAIProviders,
  Ankole.Plugins.DingTalkAdapter,
  Ankole.Plugins.DiscordAdapter,
  Ankole.Plugins.EmailAdapter,
  Ankole.Plugins.GoogleWorkspaceAdapter,
  Ankole.Plugins.LarkAdapter,
  Ankole.Plugins.LineAdapter,
  Ankole.Plugins.Microsoft365Adapter,
  Ankole.Plugins.SlackAdapter,
  Ankole.Plugins.TelegramAdapter,
  Ankole.Plugins.WeComAdapter,
  Ankole.Plugins.WhatsAppAdapter
]

# The Email adapter converts GB2312, GBK, and Windows-1252 mail to UTF-8
# through these codepagex tables; each extra table adds compile time.
config :codepagex, :encodings, [
  :ascii,
  "ISO8859/8859-1",
  "VENDORS/MICSFT/WINDOWS/CP1252",
  "VENDORS/MICSFT/WINDOWS/CP936"
]

config :ankole, AnkoleWeb.Endpoint,
  url: [host: "ankole.localhost"],
  adapter: Bandit.PhoenixAdapter,
  http: [websocket_options: [max_fragmented_message_size: 32 * 1024 * 1024]],
  render_errors: [
    formats: [html: AnkoleWeb.ErrorHTML, json: AnkoleWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ankole.PubSub

config :boruta, Boruta.Oauth,
  repo: Ankole.Repo,
  contexts: [
    access_tokens: Ankole.OIDC.Boruta.AccessTokens,
    clients: Ankole.OIDC.Boruta.Clients,
    codes: Ankole.OIDC.Boruta.Codes,
    resource_owners: Ankole.OIDC.Boruta.ResourceOwners,
    scopes: Ankole.OIDC.Boruta.Scopes
  ],
  max_ttl: [
    authorization_code: 5 * 60,
    access_token: 30 * 60,
    id_token: 5 * 60,
    refresh_token: 30 * 24 * 60 * 60
  ],
  token_generator: Ankole.OIDC.Boruta.TokenGenerator,
  issuer: "http://ankole.localhost:4000"

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
  notifier: Oban.Notifiers.PG,
  queues: [default: 10, agent_workers: 20, conversations: 20, outbox: 20],
  plugins: [
    Oban.Plugins.Pruner,
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Ankole.Sessions.Jobs.EnqueueDailySessionResets},
       {"* * * * *", Ankole.Brain.Jobs.Tick},
       {"* * * * *", Ankole.Sessions.Reconciler},
       {"*/5 * * * *", Ankole.IdentityProviders.Jobs.EnqueueDirectorySyncs},
       {"*/15 * * * *", Ankole.Signals.Jobs.CleanupExpiredState},
       {"41 * * * *", Ankole.AIGateway.Jobs.CleanupExpiredArtifacts},
       {"41 * * * *", Ankole.OIDC.Jobs.CleanupExpiredCredentials},
       {"23 * * * *", Ankole.Files.Jobs.CollectUnreferenced},
       {"* * * * *", Ankole.AgentWorkers.SweepJob},
       {"*/5 * * * *", Ankole.AgentWorkers.SweepJob, args: %{objects: true}}
     ]}
  ]

edition = Mix.Project.config()[:ankole_edition]
artifacts = Path.expand("../_build/#{edition}", __DIR__)
public_entries = Path.expand("../../webapps/entries.json", __DIR__)
entries = public_entries |> File.read!() |> :json.decode()

if edition == :saas do
  source = Path.expand("../../../internals/control_plane/config.exs", __DIR__)
  unless File.regular?(source), do: raise("Missing SaaS source: #{source}")
  import_config source

  private_entries = Path.expand("../../../internals/webapps/entries.json", __DIR__)
  private = private_entries |> File.read!() |> :json.decode()
  duplicates = Map.keys(entries) -- (Map.keys(entries) -- Map.keys(private))
  if duplicates != [], do: raise("Duplicate webapp entries: #{inspect(duplicates)}")

  config :ankole,
         :webapp_entries,
         Map.merge(
           entries,
           Map.new(private, fn {name, file} ->
             {name, "/@fs/" <> Path.expand(file, Path.dirname(private_entries))}
           end)
         )

  config :ankole,
         :internal_migrations_path,
         Path.expand("../../../internals/control_plane/priv/repo/migrations", __DIR__)
else
  config :ankole, :webapp_entries, entries
end

config :ankole, :edition, edition
config :ankole, :webapp_assets_path, Path.join(artifacts, "webapps/assets")
config :ankole, :i18n, locales_dir: Path.join(artifacts, "locales")

import_config "#{config_env()}.exs"
