import Config

config :ankole,
       :control_plane_plugin_modules,
       read_config(:ankole)[:control_plane_plugin_modules] ++
         [
           Ankole.EditionFixture.PodSettingsPlugin,
           Ankole.EditionFixture.ChallengePlugin,
           Ankole.EditionFixture.QuotaPlugin
         ]

config :ankole, :http_entry, Ankole.EditionFixture.Router
config :ankole, :host_policy, Ankole.EditionFixture.HostPolicy
config :ankole, :edition_config, Ankole.EditionFixture.Config
config :ankole, :site_identity_sources, [{"fixture-site", Ankole.EditionFixture.Source}]

config :ankole, :feature_flags, [
  {"fixture.experiment", [default: true, client_visible: true]},
  {"fixture.pod-module", [default: true, client_visible: true]},
  {"fixture.auth-challenge", [default: true, client_visible: true]}
]
