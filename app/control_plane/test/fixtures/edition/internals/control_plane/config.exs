import Config
config :ankole, :http_entry, Ankole.EditionFixture.Router
config :ankole, :host_policy, Ankole.EditionFixture.HostPolicy
config :ankole, :edition_config, Ankole.EditionFixture.Config
config :ankole, :site_identity_sources, [{"fixture-site", Ankole.EditionFixture.Source}]
