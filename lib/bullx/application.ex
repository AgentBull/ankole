defmodule BullX.Application do
  @moduledoc """
  Top-level OTP application for the BullX installation.

  Startup order keeps durable infrastructure first, then config projections,
  plugin discovery, runtime workers, and finally the web endpoint. The children
  under `BullX.Runtime.Supervisor` are reconstructible runtime activity, while
  PostgreSQL remains the source of durable facts.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BullXWeb.Telemetry,
      BullX.Repo,
      BullX.Config.Supervisor,
      BullX.I18n.Catalog,
      {Phoenix.PubSub, name: BullX.PubSub},
      BullX.Plugins.Supervisor,
      BullX.Runtime.Supervisor,
      BullXWeb.Endpoint
    ]

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
