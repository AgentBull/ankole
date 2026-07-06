import Config

Code.require_file("support/bootstrap.exs", __DIR__)

Ankole.Config.Bootstrap.load_dotenv!(
  root: Path.expand("..", __DIR__),
  env: config_env()
)

runtime_fabric_bind_endpoint =
  System.get_env("ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT") ||
    System.get_env("ANKOLE_RUNTIME_FABRIC_ENDPOINT")

if runtime_fabric_bind_endpoint do
  config :ankole, :actor_runtime_router, bind_endpoint: runtime_fabric_bind_endpoint
end

case Ankole.Config.Bootstrap.env_path_list("ANKOLE_PLUGIN_PATHS", nil) do
  nil -> :ok
  paths -> config :ankole, Ankole.Plugins.Discovery, paths: paths
end

library_runtime_config =
  []
  |> then(fn config ->
    case System.get_env("ANKOLE_LIBRARY_ROOT") do
      nil -> config
      "" -> config
      root -> Keyword.put(config, :library_root, root)
    end
  end)
  |> then(fn config ->
    case System.get_env("ANKOLE_INTERNAL_SKILLS_ROOT") do
      nil -> config
      "" -> config
      root -> Keyword.put(config, :internal_skills_root, root)
    end
  end)

if library_runtime_config != [] do
  config :ankole, Ankole.AIAgent.Library, library_runtime_config
end

case System.get_env("ANKOLE_LOG_LEVEL") do
  nil ->
    :ok

  "" ->
    :ok

  value ->
    level =
      case value |> String.trim() |> String.downcase() do
        "debug" -> :debug
        "info" -> :info
        "notice" -> :notice
        "warn" -> :warning
        "warning" -> :warning
        "error" -> :error
        "fatal" -> :critical
        "critical" -> :critical
        "alert" -> :alert
        "emergency" -> :emergency
        invalid -> raise "invalid ANKOLE_LOG_LEVEL=#{inspect(invalid)}"
      end

    config :logger, level: level
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ankole start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if Ankole.Config.Bootstrap.env_boolean("PHX_SERVER", false) do
  config :ankole, AnkoleWeb.Endpoint, server: true
end

port = Ankole.Config.Bootstrap.env_integer("PORT", 4000)
Ankole.Config.Bootstrap.validate_port!(port, "PORT")

config :ankole, AnkoleWeb.Endpoint,
  http: [port: port],
  secret_key_base: Ankole.Config.Bootstrap.endpoint_secret_key_base!()

case Ankole.Config.Bootstrap.env_string("ANKOLE_AI_GATEWAY_WORKER_FACING_BASE_URL") do
  nil ->
    :ok

  worker_facing_base_url ->
    config :ankole, Ankole.ActorRuntime.AIGatewayApiKeyBroker,
      worker_facing_base_url: worker_facing_base_url
end

if config_env() == :prod do
  database_url = Ankole.Config.Bootstrap.env!("DATABASE_URL")

  maybe_ipv6 =
    if Ankole.Config.Bootstrap.env_boolean("ECTO_IPV6", false), do: [:inet6], else: []

  config :ankole, Ankole.Repo,
    # ssl: true,
    url: database_url,
    pool_size: Ankole.Config.Bootstrap.env_integer("POOL_SIZE", 10),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  host = Ankole.Config.Bootstrap.env_string("PHX_HOST", "example.com")

  config :ankole, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ankole, AnkoleWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ]

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ankole, AnkoleWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ankole, AnkoleWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
