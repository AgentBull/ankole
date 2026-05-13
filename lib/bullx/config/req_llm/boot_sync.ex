defmodule BullX.Config.ReqLLM.BootSync do
  @moduledoc false

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def start_link(_opts) do
    BullX.Config.ReqLLM.Bridge.sync_all()
    :ignore
  end
end
