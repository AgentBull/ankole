defmodule BullX.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BullXWeb.Telemetry,
      BullX.Repo,
      BullX.Config.Supervisor,
      BullXAccounts.AuthZ.Cache,
      BullXAccounts.AuthZ.Bootstrap,
      BullXAccounts.Bootstrap,
      BullX.I18n.Catalog,
      {DNSCluster, query: Application.get_env(:bullx, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: BullX.PubSub},
      BullXAIAgent.Supervisor,
      BullXGateway.CoreSupervisor,
      BullX.Skills.Supervisor,
      BullXBrain.Supervisor,
      BullX.Runtime.Supervisor,
      BullXGateway.AdapterSupervisor,
      BullXWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BullX.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BullXWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
