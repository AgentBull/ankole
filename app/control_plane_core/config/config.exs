import Config

# A resource action uses the transaction of its calling generic action. It is
# atomic only when it declares require_atomic? true.
config :ash,
  disable_async?: true,
  default_string_length_count: :codepoints,
  require_atomic_by_default?: false

edition = if System.get_env("ANKOLE_EDITION", "foss") == "saas", do: :saas, else: :foss

config :ankole, :edition, edition

config :mime, :types, %{
  "text/event-stream" => ["event-stream"],
  "application/vnd.api+json" => ["json_api"]
}

# The JSON:API filter parameter uses the OpenAPI form that client generators read.
config :ash_json_api, use_deep_object_for_filter_type?: false

config :phoenix, :json_library, Ankole.JSON
config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase
config :tzdata, :autoupdate, :disabled

config :codepagex, :encodings, [
  :ascii,
  "ISO8859/8859-1",
  "VENDORS/MICSFT/WINDOWS/CP1252",
  "VENDORS/MICSFT/WINDOWS/CP936"
]
