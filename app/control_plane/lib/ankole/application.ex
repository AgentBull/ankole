defmodule Ankole.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    signals_gateway_opts = Application.get_env(:ankole, :signals_gateway, [])

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
    #   - PubSub + SignalsGateway preview/batch children before ActorRuntime:
    #     inbound debounce can finalize actor events and start preview handlers.
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
      |> maybe_add_child(
        signals_gateway_child(signals_gateway_opts, :inbound_batch_finalizer),
        enabled?(signals_gateway_opts, :inbound_batch_finalizer, true)
      )
      |> maybe_add_child(
        signals_gateway_child(signals_gateway_opts, :recovery_scan),
        enabled?(signals_gateway_opts, :recovery_scan, true)
      )

    children =
      children ++
        [
          Ankole.ActorRuntime.Supervisor,
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

  defp signals_gateway_child(opts, :inbound_batch_finalizer) do
    {Ankole.SignalsGateway.InboundBatchFinalizer, child_opts(opts, :inbound_batch_finalizer)}
  end

  defp signals_gateway_child(opts, :recovery_scan) do
    {Ankole.SignalsGateway.RecoveryScan, child_opts(opts, :recovery_scan)}
  end

  defp enabled?(opts, key, default) do
    case Keyword.get(opts, key) do
      nil -> default
      enabled when is_boolean(enabled) -> enabled
      child_opts when is_list(child_opts) -> Keyword.get(child_opts, :enabled, default)
      _invalid -> default
    end
  end

  defp child_opts(opts, key) do
    case Keyword.get(opts, key, []) do
      child_opts when is_list(child_opts) -> Keyword.delete(child_opts, :enabled)
      _invalid -> []
    end
  end
end
