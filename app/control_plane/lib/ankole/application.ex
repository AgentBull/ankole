defmodule Ankole.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
