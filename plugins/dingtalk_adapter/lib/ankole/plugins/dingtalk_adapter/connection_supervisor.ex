defmodule Ankole.Plugins.DingTalkAdapter.ConnectionSupervisor do
  @moduledoc """
  Starts or reuses one Stream long-connection owner for each `{"dingtalk", clientId}`.
  """

  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.DingTalkAdapter.ConnectionOwner

  @registry Ankole.Plugins.DingTalkAdapter.ConnectionRegistry
  @supervisor Ankole.Plugins.DingTalkAdapter.ConnectionDynamicSupervisor

  @type consumer :: map()

  @doc "Ensures exactly one local connection owner exists for a normalized app key."
  @spec ensure_started(map(), [consumer()]) :: {:ok, pid()} | {:error, term()}
  def ensure_started(config, consumers) when is_map(config) and is_list(consumers) do
    key = Config.connection_key(config)

    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> ensure_existing(pid, config, consumers)
      [] -> start_owner(config, consumers)
    end
  end

  @doc "Stops the connection owner registered under a key, if any."
  @spec stop(term()) :: :ok | {:error, term()}
  def stop(key) do
    case Registry.lookup(@registry, key) do
      [{pid, _value}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end
  end

  @doc "Lists connection keys currently owned in this BEAM process."
  @spec registered_keys() :: [term()]
  def registered_keys do
    @registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  defp ensure_existing(pid, config, consumers) do
    case ConnectionOwner.ensure_consumers(pid, config, consumers) do
      {:ok, ^pid} ->
        {:ok, pid}

      # A rotated app secret restarts the owner with the new credentials, the
      # same way a changed consumer set does. Two configs that disagree about
      # the secret inside one reconcile pass are still rejected on the desired
      # side before this call.
      {:error, reason} when reason in [:consumer_set_changed, :conflicting_app_secret] ->
        restart_owner(pid, config, consumers)

      {:error, _reason} = error ->
        error
    end
  end

  defp restart_owner(pid, config, consumers) do
    with :ok <- DynamicSupervisor.terminate_child(@supervisor, pid) do
      start_owner(config, consumers)
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
