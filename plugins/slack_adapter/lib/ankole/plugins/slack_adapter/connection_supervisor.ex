defmodule Ankole.Plugins.SlackAdapter.ConnectionSupervisor do
  @moduledoc false

  alias Ankole.Plugins.SlackAdapter.{Config, ConnectionOwner}

  @registry Ankole.Plugins.SlackAdapter.ConnectionRegistry
  @supervisor Ankole.Plugins.SlackAdapter.ConnectionDynamicSupervisor

  @spec ensure_started(map(), [map()]) :: {:ok, pid()} | {:error, term()}
  def ensure_started(config, consumers) do
    case Registry.lookup(@registry, Config.connection_key(config)) do
      [{pid, _value}] -> ensure_existing(pid, config, consumers)
      [] -> start_owner(config, consumers)
    end
  end

  @spec stop(term()) :: :ok | {:error, term()}
  def stop(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end
  end

  @spec registered_keys() :: [term()]
  def registered_keys do
    @registry |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()
  end

  defp ensure_existing(pid, config, consumers) do
    case ConnectionOwner.ensure_consumers(pid, config, consumers) do
      {:ok, ^pid} ->
        {:ok, pid}

      {:error, reason} when reason in [:conflicting_app_secret, :consumer_set_changed] ->
        with :ok <- DynamicSupervisor.terminate_child(@supervisor, pid),
             do: start_owner(config, consumers)

      {:error, _reason} = error ->
        error
    end
  end

  defp start_owner(config, consumers) do
    case DynamicSupervisor.start_child(
           @supervisor,
           {ConnectionOwner, config: config, consumers: consumers}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> ensure_existing(pid, config, consumers)
      {:error, _reason} = error -> error
    end
  end
end
