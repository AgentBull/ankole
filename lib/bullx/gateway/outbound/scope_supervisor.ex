defmodule BullX.Gateway.Outbound.ScopeSupervisor do
  @moduledoc false

  alias BullX.Gateway.Outbound.ScopeWorker

  @spec start_scope(map()) :: :ok
  def start_scope(scope) when is_map(scope) do
    case DynamicSupervisor.start_child(__MODULE__, {ScopeWorker, scope}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> :ok
    end
  end
end
