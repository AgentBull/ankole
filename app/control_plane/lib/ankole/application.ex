defmodule Ankole.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    runtime_events_opts = Application.get_env(:ankole, :runtime_events, [])

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
    #   - PubSub + SignalsGateway preview children before ActorRuntime:
    #     finalized actor events can start preview handlers.
    #   - RuntimeEvents after ActorRuntime: LISTEN is followed by a snapshot of
    #     durable rows into exact per-key timers.
    #   - Endpoint last: accept web traffic only after every subsystem it serves
    #     (auth, config, plugins, actors, i18n) is ready.
    children =
      [
        AnkoleWeb.Telemetry,
        Ankole.Repo,
        Ankole.AppConfigure.Registry,
        Ankole.AppConfigure.Cache,
        Ankole.Setup.Bootstrap,
        {Oban, Application.fetch_env!(:ankole, Oban)},
        {Ankole.Plugins.Registry, name: Ankole.Plugins.Registry},
        {Ankole.Plugins.Supervisor, registry: Ankole.Plugins.Registry},
        {Phoenix.PubSub, name: Ankole.PubSub},
        {Registry, keys: :unique, name: Ankole.SignalsGateway.PreviewRegistry},
        {DynamicSupervisor, name: Ankole.SignalsGateway.PreviewSupervisor, strategy: :one_for_one}
      ]

    children =
      children ++
        [
          Ankole.ActorRuntime.Supervisor
        ]

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
          Ankole.I18n.Catalog,
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
