defmodule BullX.Config.Supervisor do
  @moduledoc """
  Supervises reconstructible runtime configuration projections.

  The children here rebuild process-local views from durable config tables and
  synchronize dependent libraries after boot. No durable configuration truth is
  owned by this supervisor.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      BullX.Config.Cache,
      BullX.Config.ReqLLM.BootSync,
      BullX.Cache.Bootstrap
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
