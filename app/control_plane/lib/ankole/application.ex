defmodule Ankole.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Child order is load-bearing, not cosmetic. `:one_for_one` restarts a single
    # failed child in place, but the initial boot still proceeds top to bottom, so
    # anything later may assume earlier children are already up.
    #
    #   - Repo before AppConfigure: durable config is read from Postgres.
    #   - AppConfigure.Registry + Cache before Plugins/I18n: those subsystems read
    #     and register AppConfigure definitions during their own `init/1`.
    #   - Plugins.Registry before Plugins.Supervisor: the registry discovers and
    #     activates plugins, then the supervisor reads that active set to know
    #     which plugin-contributed children to start (snapshot taken once at boot).
    #   - Endpoint last: accept web traffic only after every subsystem it serves
    #     (auth, config, plugins, actors, i18n) is ready.
    children = [
      AnkoleWeb.Telemetry,
      Ankole.Repo,
      Ankole.AppConfigure.Registry,
      Ankole.AppConfigure.Cache,
      Ankole.Setup.Bootstrap,
      {Oban, Application.fetch_env!(:ankole, Oban)},
      {Ankole.Plugins.Registry, name: Ankole.Plugins.Registry},
      {Ankole.Plugins.Supervisor, registry: Ankole.Plugins.Registry},
      Ankole.ActorRuntime.Supervisor,
      Ankole.AIGateway.ModelMetadata.Cache,
      Ankole.I18n.Catalog,
      {DNSCluster, query: Application.get_env(:ankole, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Ankole.PubSub},
      AnkoleWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Ankole.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AnkoleWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
