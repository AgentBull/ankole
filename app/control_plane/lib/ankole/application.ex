defmodule Ankole.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    runtime_events_opts = Application.get_env(:ankole, :runtime_events, [])

    identity_provider_startup_sync_opts =
      Application.get_env(:ankole, :identity_provider_startup_sync, [])

    # Child order is load-bearing, not cosmetic. `:one_for_one` restarts a single
    # failed child in place, but the initial boot still proceeds top to bottom, so
    # anything later may assume earlier children are already up.
    #
    #   - Repo before AppConfigure: durable config is read from PostgreSQL.
    #   - AppConfigure.Registry + Cache before Plugins/I18n: those subsystems read
    #     and register AppConfigure definitions during their own `init/1`.
    #   - Observability after AppConfigure: the OTLP exporter reads its durable
    #     endpoint and secret headers once during control-plane startup.
    #   - I18n before Plugins/SignalsGateway: adapter startup and recovered Actor
    #     replies may render user-facing text immediately during their own startup.
    #   - Setup.Bootstrap before Plugins.Registry: the registry reads the durable
    #     setup state to decide whether the installation still needs every
    #     compiled plugin during first-run configuration.
    #   - Plugins.Cohort after setup: it resolves one immutable activation snapshot,
    #     starts Plugins.Registry, then starts every child that consumes that snapshot.
    #   - IdentityProviders.StartupSync after Oban + Plugins: full-sync enqueue
    #     needs the queue, active provider config, and adapter declarations.
    #   - PubSub + AIGateway credential and response-stream processes before
    #     SignalsGateway: a recovered Actor turn may select a credential and open a
    #     provider stream.
    #   - SignalsGateway owns both preview and ActorRuntime supervision, keeping
    #     their restart escalation inside the SignalsGateway failure domain.
    #   - RuntimeEvents after SignalsGateway: LISTEN is followed by a snapshot of
    #     durable rows into exact per-key timers.
    #   - Endpoint last: accept web traffic only after every subsystem it serves
    #     (auth, config, plugins, actors, i18n) is ready.
    children =
      [
        AnkoleWeb.Telemetry,
        Ankole.Repo,
        Ankole.AppConfigure.Registry,
        Ankole.AppConfigure.Cache,
        Ankole.Observability,
        Ankole.I18n.Catalog,
        Ankole.Setup.Bootstrap,
        {Oban, Application.fetch_env!(:ankole, Oban)},
        Ankole.Plugins.Cohort,
        {Phoenix.PubSub, name: Ankole.PubSub},
        Ankole.AIGateway.CredentialPool,
        {Task.Supervisor, name: Ankole.AIGateway.ProgramTaskSupervisor, max_children: 4},
        {Task.Supervisor,
         name: Ankole.AIGateway.ResponseRecoveryTaskSupervisor, max_children: 16},
        Ankole.AIGateway.ResponseStream.Supervisor,
        Ankole.SignalsGateway.Supervisor
      ]

    children =
      children
      |> maybe_add_child(
        {Ankole.IdentityProviders.StartupSync, child_opts(identity_provider_startup_sync_opts)},
        enabled?(identity_provider_startup_sync_opts, true)
      )

    children =
      children
      |> maybe_add_child(
        {Ankole.RuntimeEvents.Supervisor, child_opts(runtime_events_opts)},
        enabled?(runtime_events_opts, true)
      )

    children =
      children ++
        [
          Ankole.AIGateway.ModelMetadata.Cache,
          {DNSCluster, query: Application.get_env(:ankole, :dns_cluster_query) || :ignore},
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

  defp maybe_add_child(children, _child, false), do: children
  defp maybe_add_child(children, child, true), do: children ++ [child]

  defp enabled?(opts, default) do
    case Keyword.get(opts, :enabled) do
      nil -> default
      enabled when is_boolean(enabled) -> enabled
      _invalid -> default
    end
  end

  defp child_opts(opts) when is_list(opts), do: Keyword.delete(opts, :enabled)
  defp child_opts(_opts), do: []
end
