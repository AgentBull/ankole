[
  import_deps: [:ecto, :ecto_sql, :open_api_spex, :phoenix],
  subdirectories: ["priv/*/migrations"],
  inputs: [
    "*.{heex,ex,exs}",
    "lib/**/*.{heex,ex,exs}",
    "config/**/*.{heex,ex,exs}",
    "e2e/**/*.{heex,ex,exs}",
    "test/**/*.{heex,ex,exs}",
    "tools/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
