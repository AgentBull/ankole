import Config

Code.require_file("support/bootstrap.exs", __DIR__)

Ankole.Config.Bootstrap.load_dotenv!(
  root: Path.expand("..", __DIR__),
  env: config_env()
)

# AppConfigure is the only owner of trace export. Remove standard exporter
# variables before the OpenTelemetry application starts, or OS configuration
# can override the default-off SDK configuration below the application layer.
ankole_trace_exporter_environment_variables = ~w(
  OTEL_EXPORTER_OTLP_COMPRESSION
  OTEL_EXPORTER_OTLP_ENDPOINT
  OTEL_EXPORTER_OTLP_HEADERS
  OTEL_EXPORTER_OTLP_PROTOCOL
  OTEL_EXPORTER_OTLP_TRACES_COMPRESSION
  OTEL_EXPORTER_OTLP_TRACES_ENDPOINT
  OTEL_EXPORTER_OTLP_TRACES_HEADERS
  OTEL_EXPORTER_OTLP_TRACES_PROTOCOL
  OTEL_TRACES_EXPORTER
)

Enum.each(ankole_trace_exporter_environment_variables, &System.delete_env/1)

# AppConfigure selects the process-wide OTLP exporter after PostgreSQL-backed
# settings are available. The exporter is disabled by default. ANKOLE_ENV and
# ANKOLE_VERSION label exported traces the same way they label logs.
ankole_otel_env_text = fn name ->
  case String.trim(System.get_env(name, "")) do
    "" -> nil
    value -> value
  end
end

ankole_otel_service =
  case ankole_otel_env_text.("ANKOLE_VERSION") do
    nil -> %{name: "ankole-control-plane"}
    version -> %{name: "ankole-control-plane", version: version}
  end

ankole_otel_resource =
  case ankole_otel_env_text.("ANKOLE_ENV") do
    nil ->
      %{service: ankole_otel_service}

    environment ->
      %{
        service: ankole_otel_service,
        deployment: %{environment: %{name: environment}}
      }
  end

config :opentelemetry,
  traces_exporter: :none,
  resource: ankole_otel_resource

runtime_fabric_bind_endpoint = System.get_env("ANKOLE_RUNTIME_FABRIC_BIND_ENDPOINT")

if runtime_fabric_bind_endpoint do
  config :ankole, :actor_runtime_router, bind_endpoint: runtime_fabric_bind_endpoint
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

if Ankole.Config.Bootstrap.env_boolean("PHX_SERVER", false) do
  config :ankole, AnkoleWeb.Endpoint, server: true
end

port = Ankole.Config.Bootstrap.env_integer("PORT", 4000)
Ankole.Config.Bootstrap.validate_port!(port, "PORT")

config :ankole, AnkoleWeb.Endpoint,
  http: [port: port],
  secret_key_base: Ankole.Config.Bootstrap.endpoint_secret_key_base!()

case Ankole.Config.Bootstrap.env_string("ANKOLE_AI_GATEWAY_BASE_URL") do
  base_url when is_binary(base_url) ->
    config :ankole, Ankole.SignalsGateway.ActorRuntime.AIGatewayAPIKeyBroker, base_url: base_url

  nil ->
    :ok
end

# Dev-only Lark transport seam: point every Lark client of this instance at a
# local fake platform (tools/fake-feishu). The gate on :dev keeps the
# production rule that stored binding config and environment cannot override
# the provider endpoint.
if config_env() == :dev do
  case Ankole.Config.Bootstrap.env_string("ANKOLE_LARK_BASE_URL_OVERRIDE") do
    base_url when is_binary(base_url) ->
      config :ankole, Ankole.Plugins.LarkAdapter.Config, client_opts: [base_url: base_url]

    nil ->
      :ok
  end
end

if config_env() == :prod do
  database_url = Ankole.Config.Bootstrap.env!("DATABASE_URL")

  maybe_ipv6 =
    if Ankole.Config.Bootstrap.env_boolean("ECTO_IPV6", false), do: [:inet6], else: []

  config :ankole, Ankole.Repo,
    url: database_url,
    pool_size: Ankole.Config.Bootstrap.env_integer("POOL_SIZE", 10),
    socket_options: maybe_ipv6

  host = Ankole.Config.Bootstrap.env_string("PHX_HOST", "example.com")

  config :ankole, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ankole, AnkoleWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ]

  config :boruta, Boruta.Oauth, issuer: "https://#{host}"
end
