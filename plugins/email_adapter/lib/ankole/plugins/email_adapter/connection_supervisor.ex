defmodule Ankole.Plugins.EmailAdapter.ConnectionSupervisor do
  @moduledoc false

  alias Ankole.Plugins.EmailAdapter.ConnectionOwner
  alias Ankole.SignalsGateway.AdapterContext

  @registry Ankole.Plugins.EmailAdapter.ConnectionRegistry
  @supervisor Ankole.Plugins.EmailAdapter.ConnectionDynamicSupervisor

  @spec ensure_started(map(), [map()]) :: {:ok, pid()} | {:error, term()}
  def ensure_started(config, [%{context: %AdapterContext{} = context} = consumer]) do
    key = {context.agent_uid, context.binding_name}

    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> ensure_existing(pid, key, config, consumer)
      [] -> start_owner(key, config, consumer)
    end
  end

  def ensure_started(_config, _consumers), do: {:error, :invalid_email_consumer}

  @spec stop({String.t(), String.t()}) :: :ok | {:error, term()}
  def stop(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end
  end

  @spec registered_keys() :: [{String.t(), String.t()}]
  def registered_keys do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  defp ensure_existing(pid, key, config, consumer) do
    case ConnectionOwner.ensure_configuration(pid, config, consumer) do
      {:ok, ^pid} ->
        {:ok, pid}

      {:error, :configuration_changed} ->
        case DynamicSupervisor.terminate_child(@supervisor, pid) do
          result when result in [:ok, {:error, :not_found}] ->
            start_owner(key, config, consumer)

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp start_owner(key, config, consumer) do
    case DynamicSupervisor.start_child(
           @supervisor,
           {ConnectionOwner, key: key, config: config, consumer: consumer}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> ensure_existing(pid, key, config, consumer)
      {:error, _reason} = error -> error
    end
  end
end
