import Config

config :ash,
  disable_async?: true,
  default_string_length_count: :codepoints

ash_domains = [
  Ankole.AgentWorkers.Domain,
  Ankole.AgentWorkers.WorkerEnv.Domain,
  Ankole.AIGateway.Domain,
  Ankole.AIGateway.ProviderConfigs.Domain,
  Ankole.AIAgent.Library.Domain,
  Ankole.AppConfigure.Domain,
  Ankole.AuthZ.Domain,
  Ankole.AutomationJobs.Domain,
  Ankole.BackgroundAgentJobs.Domain,
  Ankole.BrowserSessions.Domain,
  Ankole.Brain.Domain,
  Ankole.Conversations.Domain,
  Ankole.Files.Domain,
  Ankole.IdentityProviders.Domain,
  Ankole.OIDC.Domain,
  Ankole.Pod.Domain,
  Ankole.Principals.Domain,
  Ankole.Schedule.Domain,
  Ankole.Sessions.Domain,
  Ankole.Signals.Domain,
  Ankole.Tenants.Domain,
  Ankole.Workflow.Domain
]

edition = if System.get_env("ANKOLE_EDITION", "foss") == "saas", do: :saas, else: :foss

config :ankole, :edition, edition

ash_domains =
  if edition == :saas,
    do: ash_domains ++ [Ankole.SaaS.Domain],
    else: ash_domains

config :ankole_core, ash_domains: ash_domains

config :mime, :types, %{"text/event-stream" => ["event-stream"]}
config :phoenix, :json_library, Ankole.JSON
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

config :codepagex, :encodings, [
  :ascii,
  "ISO8859/8859-1",
  "VENDORS/MICSFT/WINDOWS/CP1252",
  "VENDORS/MICSFT/WINDOWS/CP936"
]
