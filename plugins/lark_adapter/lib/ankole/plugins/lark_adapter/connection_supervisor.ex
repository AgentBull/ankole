defmodule Ankole.Plugins.LarkAdapter.ConnectionSupervisor do
  @moduledoc """
  Starts or reuses one long-connection owner for each `domain + appId`.
  """

  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.ConnectionOwner

  @registry Ankole.Plugins.LarkAdapter.ConnectionRegistry
  @supervisor Ankole.Plugins.LarkAdapter.ConnectionDynamicSupervisor

  @type consumer :: map()

  @doc """
  Ensures exactly one local connection owner exists for a normalized app key.
  """
  @spec ensure_started(map(), [consumer()], keyword()) ::
          {:ok, pid()} | {:error, term()}
  def ensure_started(config, consumers, opts \\ []) when is_map(config) and is_list(consumers) do
    key = Config.connection_key(config)

    case Registry.lookup(registry(opts), key) do
      [{pid, _value}] ->
        ensure_existing(pid, config, consumers, opts)

      [] ->
        start_owner(config, consumers, opts)
    end
  end

  @doc """
  Lists connection keys currently owned in this BEAM process.
  """
  @spec registered_keys(keyword()) :: [term()]
  def registered_keys(opts \\ []) do
    registry(opts)
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  defp ensure_existing(pid, config, consumers, opts) do
    case ConnectionOwner.ensure_consumers(pid, config, consumers) do
      {:ok, ^pid} ->
        {:ok, pid}

      {:error, :consumer_set_changed} ->
        restart_owner(pid, config, consumers, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp restart_owner(pid, config, consumers, opts) do
    with :ok <- DynamicSupervisor.terminate_child(supervisor(opts), pid) do
      start_owner(config, consumers, opts)
    end
  end

  defp start_owner(config, consumers, opts) do
    child_opts =
      opts
      |> Keyword.take([:registry, :start_client?, :client_opts, :ws_client_module])
      |> Keyword.merge(config: config, consumers: consumers)

    case DynamicSupervisor.start_child(supervisor(opts), {ConnectionOwner, child_opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        ensure_existing(pid, config, consumers, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp registry(opts), do: Keyword.get(opts, :registry, @registry)
  defp supervisor(opts), do: Keyword.get(opts, :supervisor, @supervisor)
end
