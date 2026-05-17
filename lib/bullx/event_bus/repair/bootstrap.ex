defmodule BullX.EventBus.Repair.Bootstrap do
  @moduledoc false

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(_opts) do
    :ok = BullX.EventBus.Repair.ensure_active_target_session_jobs()
    :ignore
  end
end
