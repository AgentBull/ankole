import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

Code.require_file("support/bootstrap.exs", __DIR__)

BullX.Config.Bootstrap.load_dotenv!(
  root: Path.expand("..", __DIR__),
  env: config_env()
)

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/bullx start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if BullX.Config.Bootstrap.env_boolean("PHX_SERVER", false) do
  config :bullx, BullXWeb.Endpoint, server: true
end

port = BullX.Config.Bootstrap.env_integer("PORT", 4000)
BullX.Config.Bootstrap.validate_port!(port, "PORT")
config :bullx, BullXWeb.Endpoint, http: [port: port]

secret_base = BullX.Config.Bootstrap.env!("BULLX_SECRET_BASE", & &1)
BullX.Config.Bootstrap.validate!(secret_base, zoi: Zoi.string() |> Zoi.min(64))

config :bullx, BullXWeb.Endpoint,
  secret_key_base: BullX.Ext.derive_key(secret_base, "phoenix.secret_key_base")

if config_env() == :prod do
  database_url = BullX.Config.Bootstrap.env!("DATABASE_URL", & &1)

  maybe_ipv6 =
    if BullX.Config.Bootstrap.env_boolean("ECTO_IPV6", false), do: [:inet6], else: []

  pool_size = BullX.Config.Bootstrap.env_integer("POOL_SIZE", 10)

  config :bullx, BullX.Repo,
    # ssl: true,
    url: database_url,
    pool_size: pool_size,
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  host = BullX.Config.Bootstrap.env_string("PHX_HOST", "example.com")

  config :bullx, :dns_cluster_query, BullX.Config.Bootstrap.env_string("DNS_CLUSTER_QUERY")

  config :bullx, BullXWeb.Endpoint,
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
  #     config :bullx, BullXWeb.Endpoint,
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
  #     config :bullx, BullXWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :bullx, BullX.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: BullX.Config.Bootstrap.env_string("MAILGUN_API_KEY"),
  #       domain: BullX.Config.Bootstrap.env_string("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
