defmodule Ankole.AppConfigure do
  @moduledoc """
  Database-backed runtime configuration for Ankole.
  """

  import Ecto.Query

  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Codec
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.Resolution
  alias Ankole.Repo

  @global_scope "global"
  @agent_scope_prefix "agent:"

  @type definition :: Definition.t() | PatternDefinition.t()
  @type stale_write :: {:persisted_but_stale, %{String.t() => term()}, term()}

  @doc """
  Builds an exact AppConfigure definition and raises on invalid declaration data.

  Definitions are expected to be created at boot or module load time. A bad
  definition is a programmer error, so the raising variant keeps callers simple.
  """
  @spec define(keyword() | map()) :: Definition.t()
  def define(attrs), do: Definition.new!(attrs)

  @doc """
  Builds a pattern-backed AppConfigure definition and raises on invalid declaration data.

  Pattern definitions cover runtime-computed keys while keeping the same schema
  and encryption contract as exact keys.
  """
  @spec define_pattern(keyword() | map()) :: PatternDefinition.t()
  def define_pattern(attrs), do: PatternDefinition.new!(attrs)

  @doc """
  Registers exact keys that may be read or written by AppConfigure.

  Unknown keys are rejected before persistence, so registration is the boundary
  that keeps runtime configuration from becoming an unbounded key-value store.
  """
  @spec register_definitions([Definition.t()]) :: :ok | {:error, term()}
  def register_definitions(definitions), do: Registry.register_definitions(definitions)

  @doc """
  Registers runtime key patterns for plugin-like configuration families.

  Exact definitions still win over patterns. If more than one pattern matches a
  key, the registry rejects the key instead of letting load order choose policy.
  """
  @spec register_patterns([PatternDefinition.t()]) :: :ok | {:error, term()}
  def register_patterns(patterns), do: Registry.register_patterns(patterns)

  @doc """
  Resolves a typed definition to its effective value and source metadata.

  With `:agent_id`, resolution checks the agent scope first, then `global`, then
  the code default. Without `:agent_id`, it starts at `global`. Only missing
  rows fall back; invalid rows return a storage error.
  """
  @spec resolve(Definition.t(), keyword()) :: {:ok, Resolution.t()} | :error | {:error, term()}
  def resolve(%Definition{} = definition, opts \\ []) do
    with {:ok, registered} <- Registry.require_definition(definition) do
      resolve_registered(registered, opts)
    end
  end

  @doc """
  Resolves a concrete key that may be backed by an exact or pattern definition.

  This is the runtime-key variant used when the key is only known after plugin or
  provider selection. The returned value is still validated by the matched
  definition.
  """
  @spec resolve_by_key(String.t(), keyword()) :: {:ok, Resolution.t()} | :error | {:error, term()}
  def resolve_by_key(key, opts \\ []) when is_binary(key) do
    with {:ok, registered} <- Registry.require_key(key) do
      resolve_registered(registered, Keyword.put(opts, :runtime_key, key))
    end
  end

  @doc """
  Reads the effective value for an exact definition.

  This is the common runtime API when callers only need the value and do not need
  to know whether it came from agent, global, or default scope.
  """
  @spec get(Definition.t(), keyword()) :: {:ok, term()} | :error | {:error, term()}
  def get(%Definition{} = definition, opts \\ []) do
    definition
    |> resolve(opts)
    |> value_result()
  end

  @doc """
  Reads the effective value for a concrete exact or pattern-backed key.
  """
  @spec get_by_key(String.t(), keyword()) :: {:ok, term()} | :error | {:error, term()}
  def get_by_key(key, opts \\ []) do
    key
    |> resolve_by_key(opts)
    |> value_result()
  end

  @doc """
  Generates a value for a definition that declares a generator.

  Generation does not persist. Setup or another owning write path must explicitly
  accept and store the generated value.
  """
  @spec generate(Definition.t()) :: {:ok, term()} | {:error, term()}
  def generate(%Definition{} = definition), do: Definition.generate(definition)

  @doc """
  Stores a validated value in the installation-wide `global` scope.

  The write path updates PostgreSQL first and then updates the process-local ETS
  projection, so normal runtime reads do not need a separate refresh step.
  """
  @spec put_global(Definition.t(), term()) :: {:ok, term()} | {:error, term()}
  def put_global(%Definition{} = definition, value) do
    with {:ok, registered} <- Registry.require_definition(definition) do
      put(@global_scope, registered.key, registered, value)
    end
  end

  @doc """
  Stores a validated value for a concrete exact or pattern-backed key in `global`.
  """
  @spec put_global_by_key(String.t(), term()) :: {:ok, term()} | {:error, term()}
  def put_global_by_key(key, value) when is_binary(key) do
    with {:ok, registered} <- Registry.require_key(key) do
      put(@global_scope, key, registered, value)
    end
  end

  @doc """
  Stores multiple concrete keys in `global` inside one database transaction.

  All keys are validated and encoded before any row is written. If the database
  commit succeeds but the local cache projection cannot be refreshed, the result
  is still tagged as `:persisted_but_stale` so setup or operator flows can report
  that runtime readers may need a refresh.
  """
  @spec put_many_global_by_key(map() | [{String.t(), term()}]) ::
          {:ok, %{String.t() => term()} | stale_write()} | {:error, term()}
  def put_many_global_by_key(entries) when is_map(entries) do
    entries
    |> Map.to_list()
    |> put_many_global_by_key()
  end

  def put_many_global_by_key(entries) when is_list(entries) do
    with {:ok, prepared_entries} <- prepare_many_entries(@global_scope, entries),
         {:ok, values_by_key} <- persist_many_entries(prepared_entries) do
      refresh_many_after_commit(prepared_entries, values_by_key)
    end
  end

  @doc """
  Stores a validated agent-specific override for an exact definition.

  Agent values never change the key path. The agent id only selects the
  `agent:<id>` scope so global and agent values keep the same logical key.
  """
  @spec put_for_agent(String.t(), Definition.t(), term()) :: {:ok, term()} | {:error, term()}
  def put_for_agent(agent_id, %Definition{} = definition, value) do
    with {:ok, scope} <- agent_scope(agent_id),
         {:ok, registered} <- Registry.require_definition(definition) do
      put(scope, registered.key, registered, value)
    end
  end

  @doc """
  Stores a validated agent-specific override for a concrete exact or pattern-backed key.
  """
  @spec put_for_agent_by_key(String.t(), String.t(), term()) :: {:ok, term()} | {:error, term()}
  def put_for_agent_by_key(agent_id, key, value) when is_binary(key) do
    with {:ok, scope} <- agent_scope(agent_id),
         {:ok, registered} <- Registry.require_key(key) do
      put(scope, key, registered, value)
    end
  end

  @doc """
  Deletes the `global` row for an exact definition.

  After deletion, normal reads may fall back to the code default.
  """
  @spec delete_global(Definition.t()) :: :ok | {:error, term()}
  def delete_global(%Definition{} = definition) do
    with {:ok, registered} <- Registry.require_definition(definition) do
      delete(@global_scope, registered.key)
    end
  end

  @doc """
  Deletes the `global` row for a concrete exact or pattern-backed key.
  """
  @spec delete_global_by_key(String.t()) :: :ok | {:error, term()}
  def delete_global_by_key(key) when is_binary(key) do
    with {:ok, _registered} <- Registry.require_key(key) do
      delete(@global_scope, key)
    end
  end

  @doc """
  Deletes the agent-specific row for an exact definition.

  After deletion, normal reads may fall back to `global` and then to the code
  default.
  """
  @spec delete_for_agent(String.t(), Definition.t()) :: :ok | {:error, term()}
  def delete_for_agent(agent_id, %Definition{} = definition) do
    with {:ok, scope} <- agent_scope(agent_id),
         {:ok, registered} <- Registry.require_definition(definition) do
      delete(scope, registered.key)
    end
  end

  @doc """
  Deletes the agent-specific row for a concrete exact or pattern-backed key.
  """
  @spec delete_for_agent_by_key(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_for_agent_by_key(agent_id, key) when is_binary(key) do
    with {:ok, scope} <- agent_scope(agent_id),
         {:ok, _registered} <- Registry.require_key(key) do
      delete(scope, key)
    end
  end

  # Pattern definitions use their pattern id for default generation, but reads
  # and writes must validate the concrete runtime key selected by the caller.
  defp resolve_registered(definition, opts) do
    key = Keyword.get(opts, :runtime_key, definition_key(definition))

    definition
    |> resolution_scopes(opts)
    |> resolve_scopes(definition, key)
  end

  defp resolution_scopes(_definition, opts) do
    case Keyword.fetch(opts, :agent_id) do
      {:ok, agent_id} ->
        case agent_scope(agent_id) do
          {:ok, scope} -> [scope, @global_scope]
          {:error, reason} -> {:error, reason}
        end

      :error ->
        [@global_scope]
    end
  end

  # Fallback only means "row missing". A row that exists but cannot be decoded or
  # validated is treated as a storage error because inheriting another value
  # would hide corruption or a mismatched encryption secret.
  defp resolve_scopes({:error, reason}, _definition, _key), do: {:error, reason}

  defp resolve_scopes(scopes, definition, key) do
    scopes
    |> Enum.reduce_while(:error, fn scope, :error ->
      case resolve_scope(scope, key, definition) do
        :missing -> {:cont, :error}
        result -> {:halt, result}
      end
    end)
    |> case do
      :error -> resolve_default(definition)
      result -> result
    end
  end

  defp resolve_scope(scope, key, definition) do
    case cached_or_loaded(scope, key) do
      {:ok, {:row, envelope}} -> decode_cached_row(scope, key, definition, envelope)
      {:ok, {:error, reason}} -> {:error, {:storage_error, scope, key, reason}}
      {:ok, :absent} -> :missing
      {:error, reason} -> {:error, reason}
    end
  end

  defp cached_or_loaded(scope, key) do
    case Cache.lookup(scope, key) do
      {:ok, state} -> {:ok, state}
      :miss -> Cache.load(scope, key)
    end
  end

  # Validation happens after reading from cache, not inside the cache process.
  # The cache stays a small row-state projection and does not need to know every
  # registered schema.
  defp decode_cached_row(scope, key, definition, envelope) do
    case Codec.load(definition, scope, key, envelope) do
      {:ok, value} ->
        {:ok, %Resolution{value: value, source: source_for_scope(scope), scope: scope}}

      {:error, reason} ->
        Cache.put_error(scope, key, reason)
        {:error, {:storage_error, scope, key, reason}}
    end
  end

  defp resolve_default(%{default?: true, default_value: value}) do
    {:ok, %Resolution{value: value, source: :default, scope: nil}}
  end

  defp resolve_default(_definition), do: :error

  defp value_result({:ok, %Resolution{value: value}}), do: {:ok, value}
  defp value_result(:error), do: :error
  defp value_result({:error, reason}), do: {:error, reason}

  # AppConfigure has no public refresh path. Runtime changes are expected to use
  # this write path, which persists first and then updates the local projection.
  defp put(scope, key, definition, value) do
    with {:ok, envelope, parsed} <- Codec.dump(definition, scope, key, value),
         :ok <- upsert_row(scope, key, envelope),
         :ok <- Cache.put_row(scope, key, envelope) do
      {:ok, parsed}
    end
  end

  defp prepare_many_entries(scope, entries) do
    entries
    |> Enum.reduce_while({:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) ->
        with {:ok, registered} <- Registry.require_key(key),
             {:ok, envelope, parsed} <- Codec.dump(registered, scope, key, value) do
          prepared = %{scope: scope, key: key, envelope: envelope, parsed: parsed}
          {:cont, {:ok, Map.put(acc, key, prepared)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      _entry, _acc ->
        {:halt, {:error, :invalid_entries}}
    end)
    |> case do
      {:ok, entries_by_key} -> {:ok, Map.values(entries_by_key)}
      {:error, _reason} = error -> error
    end
  end

  defp persist_many_entries([]), do: {:ok, %{}}

  defp persist_many_entries(prepared_entries) do
    Repo.transact(fn repo ->
      prepared_entries
      |> Enum.reduce_while({:ok, %{}}, fn prepared, {:ok, acc} ->
        case upsert_row(repo, prepared.scope, prepared.key, prepared.envelope) do
          :ok -> {:cont, {:ok, Map.put(acc, prepared.key, prepared.parsed)}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end)
  end

  defp refresh_many_after_commit(prepared_entries, values_by_key) do
    prepared_entries
    |> Enum.flat_map(&refresh_prepared_entry/1)
    |> case do
      [] -> {:ok, values_by_key}
      [failure] -> {:ok, {:persisted_but_stale, values_by_key, failure}}
      failures -> {:ok, {:persisted_but_stale, values_by_key, failures}}
    end
  end

  defp refresh_prepared_entry(prepared) do
    case safe_cache_put_row(prepared.scope, prepared.key, prepared.envelope) do
      :ok ->
        []

      {:error, reason} ->
        [{:app_configure_cache_projection_failed, prepared.scope, prepared.key, reason}]
    end
  end

  defp safe_cache_put_row(scope, key, envelope) do
    Cache.put_row(scope, key, envelope)
  catch
    :exit, reason -> {:error, reason}
  end

  defp upsert_row(scope, key, envelope) do
    upsert_row(Repo, scope, key, envelope)
  end

  defp upsert_row(repo, scope, key, envelope) do
    now = DateTime.utc_now(:second)

    changeset =
      AppConfig.changeset(%AppConfig{}, %{
        scope: scope,
        key: key,
        value: envelope,
        inserted_at: now,
        updated_at: now
      })

    case repo.insert(changeset,
           on_conflict: [set: [value: envelope, updated_at: now]],
           conflict_target: [:scope, :key]
         ) do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp delete(scope, key) do
    AppConfig
    |> where([row], row.scope == ^scope and row.key == ^key)
    |> Repo.delete_all()

    Cache.put_absent(scope, key)
  end

  defp definition_key(%Definition{key: key}), do: key
  defp definition_key(%PatternDefinition{id: id}), do: id

  defp agent_scope(agent_id) when is_binary(agent_id) and agent_id != "" do
    {:ok, @agent_scope_prefix <> agent_id}
  end

  defp agent_scope(_agent_id), do: {:error, :invalid_agent_id}

  defp source_for_scope(@global_scope), do: :global
  defp source_for_scope(@agent_scope_prefix <> _agent_id), do: :agent
end
