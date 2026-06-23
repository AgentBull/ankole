defmodule Ankole.AppConfigure.Registry do
  @moduledoc """
  Runtime registry for declared AppConfigure keys and key patterns.
  """

  use GenServer

  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition

  @type registered_definition :: Definition.t() | PatternDefinition.t()

  @doc """
  Starts the process that owns declared AppConfigure key metadata.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers exact definitions and rejects duplicate keys.
  """
  @spec register_definitions([Definition.t()]) :: :ok | {:error, term()}
  def register_definitions(definitions) when is_list(definitions) do
    GenServer.call(__MODULE__, {:register_definitions, definitions})
  end

  @doc """
  Registers pattern definitions and rejects duplicate pattern ids.
  """
  @spec register_patterns([PatternDefinition.t()]) :: :ok | {:error, term()}
  def register_patterns(patterns) when is_list(patterns) do
    GenServer.call(__MODULE__, {:register_patterns, patterns})
  end

  @doc """
  Requires that an exact definition has been registered.

  Public APIs use this to reject stale or ad hoc definition structs before they
  can read or write durable configuration.
  """
  @spec require_definition(Definition.t()) :: {:ok, Definition.t()} | {:error, term()}
  def require_definition(%Definition{key: key}) do
    GenServer.call(__MODULE__, {:require_definition, key})
  end

  @doc """
  Resolves a concrete key to an exact or pattern-backed definition.
  """
  @spec require_key(String.t()) :: {:ok, registered_definition()} | {:error, term()}
  def require_key(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:require_key, key})
  end

  @doc false
  @spec clear_for_test() :: :ok
  def clear_for_test do
    GenServer.call(__MODULE__, :clear_for_test)
  end

  @impl true
  def init(_opts) do
    {:ok, %{definitions: %{}, patterns: %{}}}
  end

  @impl true
  def handle_call({:register_definitions, definitions}, _from, state) do
    case put_definitions(state, definitions) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:register_patterns, patterns}, _from, state) do
    case put_patterns(state, patterns) do
      {:ok, next_state} -> {:reply, :ok, next_state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:require_definition, key}, _from, %{definitions: definitions} = state) do
    {:reply, require_exact(definitions, key), state}
  end

  @impl true
  def handle_call({:require_key, key}, _from, state) do
    {:reply, resolve_key(state, key), state}
  end

  @impl true
  def handle_call(:clear_for_test, _from, _state) do
    {:reply, :ok, %{definitions: %{}, patterns: %{}}}
  end

  defp put_definitions(state, definitions) do
    Enum.reduce_while(definitions, {:ok, state}, fn
      %Definition{} = definition, {:ok, acc} ->
        put_definition(acc, definition)

      definition, _acc ->
        {:halt, {:error, {:invalid_definition, definition}}}
    end)
  end

  defp put_definition(%{definitions: definitions} = state, %Definition{key: key} = definition) do
    case Map.has_key?(definitions, key) do
      true -> {:halt, {:error, {:duplicate_key, key}}}
      false -> {:cont, {:ok, %{state | definitions: Map.put(definitions, key, definition)}}}
    end
  end

  defp put_patterns(state, patterns) do
    Enum.reduce_while(patterns, {:ok, state}, fn
      %PatternDefinition{} = pattern, {:ok, acc} ->
        put_pattern(acc, pattern)

      pattern, _acc ->
        {:halt, {:error, {:invalid_pattern, pattern}}}
    end)
  end

  defp put_pattern(%{patterns: patterns} = state, %PatternDefinition{id: id} = pattern) do
    case Map.has_key?(patterns, id) do
      true -> {:halt, {:error, {:duplicate_pattern, id}}}
      false -> {:cont, {:ok, %{state | patterns: Map.put(patterns, id, pattern)}}}
    end
  end

  defp require_exact(definitions, key) do
    case Map.fetch(definitions, key) do
      {:ok, definition} -> {:ok, definition}
      :error -> {:error, {:unknown_key, key}}
    end
  end

  # Exact definitions have priority because they carry a more specific schema and
  # encryption policy than a broad runtime pattern.
  defp resolve_key(%{definitions: definitions, patterns: patterns}, key) do
    case Map.fetch(definitions, key) do
      {:ok, definition} -> {:ok, definition}
      :error -> resolve_pattern(patterns, key)
    end
  end

  # Ambiguous patterns are rejected instead of choosing by map order. Otherwise a
  # value could be encrypted or validated differently across restarts.
  defp resolve_pattern(patterns, key) do
    patterns
    |> Map.values()
    |> Enum.filter(&Regex.match?(&1.key_pattern, key))
    |> case do
      [] -> {:error, {:unknown_key, key}}
      [pattern] -> {:ok, pattern}
      matches -> {:error, {:ambiguous_key, key, Enum.map(matches, & &1.id)}}
    end
  end
end
