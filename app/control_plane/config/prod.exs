import Config

config :ankole, :secure_cookies, true

config :ankole, AnkoleWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info
