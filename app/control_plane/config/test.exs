import Config

config :ankole, Ankole.Repo,
  template: "template0",
  pool: Ecto.Adapters.SQL.Sandbox,
  ownership_timeout: 3_600_000,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :ankole, AnkoleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  server: false

config :boruta, Boruta.Oauth, issuer: "http://localhost:4002"

config :ankole, AnkoleWeb.Assets, dev_server: "http://assets.test"

config :ankole, Ankole.AIAgent.Library, source_cache_ttl_ms: 0

# Unit tests replace HTTP at the provider boundary when they create Workers.
config :ankole, Ankole.SignalsGateway.ActorRuntime.AgentWorkers,
  image: "ankole-agent-computer:test",
  runtime_fabric_endpoint: "ws://127.0.0.1:4002/runtime-fabric/worker",
  installation: "test"

# Each test partition gets its own file-service directory.
config :ankole, Ankole.ObjectStore,
  spec: %{
    scheme: "fs",
    root:
      Path.join(
        System.tmp_dir!(),
        "ankole-test-files#{System.get_env("MIX_TEST_PARTITION")}"
      )
  }

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :ankole, Oban, testing: :manual, plugins: false, queues: false

config :ankole, :identity_provider_startup_sync, enabled: false
config :ankole, :identity_provider_realtime_reconcile, on_save: false

# Startup reconciliation remains active. Periodic plugin processes must not
# borrow the current test's shared SQL Sandbox owner after it exits.
config :ankole, :signal_connection_reconcile_interval_ms, nil

# Lark clients send requests to port 0 of the loopback address and do not
# retry. No server can listen on port 0, so a Lark request without a test stub
# fails immediately and does not go to Feishu. A stub that a test sets with
# `Req.default_options(plug: ...)` still gets the request.
config :ankole, Ankole.Plugins.LarkAdapter.Config,
  client_opts: [base_url: "http://127.0.0.1:0", req_options: [retry: false]]

# Compile the local Worker fixture transport only in the test build.
config :ankole, :test_worker_routes, true

# The limiter test uses a real interval. Other tests do not need wall-clock waits.

# Small channel budgets keep flow-control and acknowledgement tests fast.
config :ankole, AnkoleWeb.WorkerChannel,
  command_ack_timeout_ms: 300,
  pending_command_limit: 2,
  inflight: [durable: {2, 64 * 1024 * 1024}]
