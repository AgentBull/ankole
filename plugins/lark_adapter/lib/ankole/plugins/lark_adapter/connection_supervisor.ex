defmodule Ankole.Plugins.LarkAdapter.ConnectionSupervisor do
  @moduledoc """
  Starts or reuses one long-connection owner for each `domain + appID`.
  """

  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.ConnectionOwner

  @registry Ankole.Plugins.LarkAdapter.ConnectionRegistry
  @supervisor Ankole.Plugins.LarkAdapter.ConnectionDynamicSupervisor

  @type consumer :: map()

  @doc """
  Ensures exactly one local connection owner exists for a normalized app key.
  """
  @spec ensure_started(map(), [consumer()], keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(config, consumers, opts \\ [])
      when is_map(config) and is_list(consumers) do
    registry = Keyword.get(opts, :registry, @registry)
    key = Config.connection_key(config)

    case Registry.lookup(registry, key) do
      [{pid, _value}] ->
        ensure_existing(pid, config, consumers, opts)

      [] ->
        start_owner(config, consumers, opts)
    end
  end

  @doc """
  Stops the connection owner registered under a key, if any.
  """
  @spec stop(term(), keyword()) :: :ok | {:error, term()}
  def stop(key, opts \\ []) do
    registry = Keyword.get(opts, :registry, @registry)
    supervisor = Keyword.get(opts, :supervisor, @supervisor)

    case Registry.lookup(registry, key) do
      [{pid, _value}] -> DynamicSupervisor.terminate_child(supervisor, pid)
      [] -> :ok
    end
  end

  @doc """
  Lists connection keys currently owned in this BEAM process.
  """
  @spec registered_keys(keyword()) :: [term()]
  def registered_keys(opts \\ []) do
    opts
    |> Keyword.get(:registry, @registry)
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.sort()
  end

  defp ensure_existing(pid, config, consumers, opts) do
    case ConnectionOwner.ensure_consumers(pid, config, consumers) do
      {:ok, ^pid} ->
        {:ok, pid}

      # A rotated app secret restarts the owner with the new credentials, the
      # same way a changed consumer set does. Two configs that disagree about
      # the secret inside one reconcile pass are still rejected on the desired
      # side before this call.
      {:error, reason} when reason in [:consumer_set_changed, :conflicting_app_secret] ->
        restart_owner(pid, config, consumers, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp restart_owner(pid, config, consumers, opts) do
    supervisor = Keyword.get(opts, :supervisor, @supervisor)

    with :ok <- DynamicSupervisor.terminate_child(supervisor, pid) do
      start_owner(config, consumers, opts)
    end
  end

  defp start_owner(config, consumers, opts) do
    supervisor = Keyword.get(opts, :supervisor, @supervisor)

    child_opts =
      [config: config, consumers: consumers] ++
        Keyword.take(opts, [:registry, :client_opts])

    case DynamicSupervisor.start_child(supervisor, {ConnectionOwner, child_opts}) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        ensure_existing(pid, config, consumers, opts)

      {:error, _reason} = error ->
        error
    end
  end
end
