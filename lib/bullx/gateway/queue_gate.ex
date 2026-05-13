defmodule BullX.Gateway.QueueGate do
  @moduledoc """
  Reconstructible placeholder for Gateway queue readiness control.

  The failure boundary belongs under `BullX.Gateway.Supervisor`; it does not
  move Runtime supervision. The current infra shell keeps Oban queues inactive
  in tests and leaves runtime readiness policy to the next Gateway slice.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts), do: {:ok, %{opts: opts}}
end
