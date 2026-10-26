[
  import_deps: [:ecto, :ecto_sql, :open_api_spex, :phoenix],
  subdirectories: ["priv/*/migrations"],
  inputs:
    [
      "*.{heex,ex,exs}",
      "lib/**/*.{heex,ex,exs}",
      "patches/*.exs",
      "../../plugins/*/{lib,test,scripts}/**/*.{heex,ex,exs}",
      "../../libs/{im_transport,feishu_protocol}/**/*.{ex,exs}",
      "config/**/*.{heex,ex,exs}",
      "test/**/*.{heex,ex,exs}",
      "integration/**/*.{heex,ex,exs}",
      "priv/*/seeds.exs"
    ] ++
      if(System.get_env("ANKOLE_EDITION") == "saas",
        do: ["../../internals/control_plane/**/*.{ex,exs}"],
        else: []
      )
]
