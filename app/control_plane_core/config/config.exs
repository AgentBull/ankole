import Config

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
