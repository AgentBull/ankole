import Config

if System.get_env("RELEASE_ROOT") do
  config :ankole,
         :internal_migrations_path,
         Application.app_dir(:ankole, "priv/repo/internal_migrations")

  config :ankole, :webapp_assets_path, Application.app_dir(:ankole, "priv/static/assets")
  config :ankole, :i18n, locales_dir: Application.app_dir(:ankole, "priv/locales")
end

Code.require_file("support/bootstrap.exs", __DIR__)

Ankole.Config.Bootstrap.load_dotenv!(
  root: Path.expand("..", __DIR__),
  env: config_env()
)

# Load database URLs after dotenv files in development and tests.
# The release reads its database URL in the :prod branch below.
case config_env() do
  :dev ->
    config :ankole, Ankole.Repo, url: Ankole.Config.Bootstrap.env!("DATABASE_URL")

  :test ->
    database_url = URI.parse(Ankole.Config.Bootstrap.env!("DATABASE_URL"))
    partition = Ankole.Config.Bootstrap.env_string("MIX_TEST_PARTITION")

    config :ankole, Ankole.Repo,
      url: URI.to_string(%{database_url | path: "/ankole_test#{partition}"})

  :prod ->
    :ok
end

config :ankole, Ankole.Pod.BaseCluster,
  databases:
    Ankole.Config.Bootstrap.base_databases(
      Ankole.Config.Bootstrap.env_string("BASE_DB_URLS"),
      Ankole.Config.Bootstrap.env!("DATABASE_URL"),
      config_env(),
      Ankole.Config.Bootstrap.env_string("MIX_TEST_PARTITION"),
      Application.get_env(:ankole, :edition, :foss)
    ),
  create_databases: config_env() in [:dev, :test]

config :ankole,
       :site_admin_console_path,
       System.get_env("ANKOLE_SITE_ADMIN_CONSOLE_PATH", "/site-admin-console")

config :ankole, :function_runtime,
  url:
    if(config_env() == :prod,
      do: Ankole.Config.Bootstrap.env!("ANKOLE_FUNCTION_RUNTIME_URL"),
      else: System.get_env("ANKOLE_FUNCTION_RUNTIME_URL", "http://127.0.0.1:5435")
    ),
  token:
    if(config_env() == :prod,
      do: Ankole.Config.Bootstrap.env!("ANKOLE_FUNCTION_RUNTIME_TOKEN"),
      else: System.get_env("ANKOLE_FUNCTION_RUNTIME_TOKEN", "dev-function-runtime-token")
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

# Workers reach the relay endpoint of the control-plane Pod that issued a
# relay URL, so the origin must name this Pod, never a load-balanced
# Service address. Kubernetes supplies POD_IP through the Downward API.
runtime_fabric_internal_origin =
  case {System.get_env("ANKOLE_RUNTIME_FABRIC_INTERNAL_ORIGIN"), System.get_env("POD_IP")} do
    {origin, _pod_ip} when is_binary(origin) and origin != "" ->
      origin

    {_unset, pod_ip} when is_binary(pod_ip) and pod_ip != "" ->
      "http://#{pod_ip}:#{Ankole.Config.Bootstrap.env_integer("PORT", 4000)}"

    _unset ->
      nil
  end

if runtime_fabric_internal_origin do
  config :ankole, :runtime_fabric_internal_origin, runtime_fabric_internal_origin
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
    config :ankole, Ankole.Sessions.AIGatewayAPIKeyBroker, base_url: base_url

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

# File-service bytes (attachments and drive files). Tests keep
# the per-partition directory from config/test.exs.
if config_env() != :test do
  files_store_spec = Ankole.Config.Bootstrap.files_store_spec()

  cond do
    files_store_spec ->
      config :ankole, Ankole.ObjectStore, spec: files_store_spec

    config_env() == :prod ->
      raise "ANKOLE_FILES_STORE is required; see docs/design-docs/Files.md for supported backends"

    true ->
      :ok
  end
end

edition_runtime =
  case Application.get_env(:ankole, :edition_config) do
    nil -> []
    module -> module.runtime_config(config_env())
  end

# Node startup facts; provider settings and credentials are owned by PostgreSQL.
if config_env() != :test do
  config :ankole,
         :worker_providers_file,
         Ankole.Config.Bootstrap.env_string("ANKOLE_WORKER_PROVIDERS_FILE")

  if config_env() == :prod or Ankole.Config.Bootstrap.env_string("ANKOLE_AGENT_COMPUTER_IMAGE") do
    config :ankole, Ankole.AgentWorkers,
      image: Ankole.Config.Bootstrap.env!("ANKOLE_AGENT_COMPUTER_IMAGE"),
      runtime_fabric_endpoint:
        get_in(edition_runtime, [:ankole, Ankole.AgentWorkers, :runtime_fabric_endpoint]) ||
          Ankole.Config.Bootstrap.env!("ANKOLE_WORKER_RUNTIME_FABRIC_ENDPOINT"),
      installation: Ankole.Config.Bootstrap.env_string("ANKOLE_WORKER_INSTALLATION") || "ankole"
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

  config :ankole, Ankole.OIDC.Config, issuer: "https://#{host}"
end

for {application, values} <- edition_runtime do
  config application, values
end
