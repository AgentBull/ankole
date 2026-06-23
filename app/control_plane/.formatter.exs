[
  import_deps: [:ecto, :ecto_sql, :phoenix],
  subdirectories: ["priv/*/migrations"],
  inputs: [
    "*.{heex,ex,exs}",
    "lib/**/*.{heex,ex,exs}",
    "config/**/*.{heex,ex,exs}",
    "test/**/*.{heex,ex,exs}",
    "priv/*/seeds.exs"
  ]
]
