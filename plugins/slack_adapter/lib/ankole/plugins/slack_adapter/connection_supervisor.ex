defmodule Ankole.Plugins.SlackAdapter.ConnectionSupervisor do
  @moduledoc false

  alias Ankole.Plugins.SlackAdapter.{Config, ConnectionOwner}

  @registry Ankole.Plugins.SlackAdapter.ConnectionRegistry
  @supervisor Ankole.Plugins.SlackAdapter.ConnectionDynamicSupervisor

  @spec ensure_started(map(), [map()], keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(config, consumers, opts \\ []) do
    case Registry.lookup(registry(opts), Config.connection_key(config)) do
      [{pid, _value}] -> ensure_existing(pid, config, consumers, opts)
      [] -> start_owner(config, consumers, opts)
    end
  end

  @spec registered_keys(keyword()) :: [term()]
  def registered_keys(opts \\ []) do
    registry(opts) |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}]) |> Enum.sort()
  end

  defp ensure_existing(pid, config, consumers, opts) do
    case ConnectionOwner.ensure_consumers(pid, config, consumers) do
      {:ok, ^pid} ->
        {:ok, pid}

      {:error, :consumer_set_changed} ->
        with :ok <- DynamicSupervisor.terminate_child(supervisor(opts), pid),
             do: start_owner(config, consumers, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp start_owner(config, consumers, opts) do
    child_opts =
      opts
      |> Keyword.take([:registry, :start_client?, :client_opts, :ws_client_module])
      |> Keyword.merge(config: config, consumers: consumers)

    case DynamicSupervisor.start_child(supervisor(opts), {ConnectionOwner, child_opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> ensure_existing(pid, config, consumers, opts)
      {:error, _reason} = error -> error
    end
  end

  defp registry(opts), do: Keyword.get(opts, :registry, @registry)
  defp supervisor(opts), do: Keyword.get(opts, :supervisor, @supervisor)
end
