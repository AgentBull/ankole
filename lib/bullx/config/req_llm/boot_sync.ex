defmodule BullX.Config.ReqLLM.BootSync do
  @moduledoc """
  One-shot child that projects BullX ReqLLM config into the ReqLLM app env.

  It runs during config supervision startup and returns `:ignore` because there
  is no long-lived process to supervise after the projection completes.
  """

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
