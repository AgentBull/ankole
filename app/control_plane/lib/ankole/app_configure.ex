defmodule Ankole.AppConfigure do
  @moduledoc """
  Database-backed runtime configuration for Ankole.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Codec
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.PatternDefinition
  alias Ankole.AppConfigure.Registry
  alias Ankole.AppConfigure.Resolution
  alias Ankole.Logging
  alias Ankole.Repo

  @global_scope "global"
  @agent_scope_prefix "agent:"

  @type definition :: Definition.t() | PatternDefinition.t()
  @type console_item :: map()
  @opaque committed_write :: {term(), String.t(), String.t()}

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
  Lists registered exact definitions in stable key order.

  Subsystems that project registered keys into another surface (for example
  worker shell environment exports) enumerate through this facade instead of
  reaching into the registry process.
  """
  @spec list_definitions() :: [Definition.t()]
  def list_definitions, do: Registry.list_definitions()

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

  @doc false
  @spec resolve_in_tx(module(), Definition.t(), keyword()) ::
          {:ok, Resolution.t()} | :error | {:error, term()}
  def resolve_in_tx(repo, %Definition{} = definition, opts \\ []) when is_atom(repo) do
    with {:ok, registered} <- Registry.require_definition(definition) do
      key = definition_key(registered)

      registered
      |> resolution_scopes(opts)
      |> resolve_scopes_in_tx(repo, registered, key)
    end
  end

  @doc false
  @spec get_in_tx(module(), Definition.t(), keyword()) ::
          {:ok, term()} | :error | {:error, term()}
  def get_in_tx(repo, %Definition{} = definition, opts \\ []) when is_atom(repo) do
    repo
    |> resolve_in_tx(definition, opts)
    |> value_result()
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
  Atomically transforms one installation-wide value under a per-key database lock.

  The callback receives the current PostgreSQL value, or the registered default
  when no row exists, and must return `{:ok, next_value}` or `{:error, reason}`.
  It runs exactly once while a short transaction holds the key lock, so it must
  only compute the replacement value and must not perform external I/O.
  """
  @spec update_global(Definition.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def update_global(%Definition{} = definition, updater) when is_function(updater, 1) do
    with {:ok, registered} <- Registry.require_definition(definition) do
      case Repo.transact(fn repo ->
             with :ok <- lock_global_key(repo, registered.key),
                  {:ok, current} <- current_global_value_in_tx(repo, registered),
                  {:ok, next_value} <- run_global_updater(updater, current),
                  {:ok, committed_write} <-
                    put_row(repo, @global_scope, registered.key, registered, next_value) do
               {:ok, committed_write}
             end
           end) do
        {:ok, committed_write} -> cache_committed_write(committed_write)
        {:error, _reason} = error -> error
      end
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

  @doc false
  @spec get_global_by_key_in_tx(module(), String.t()) ::
          {:ok, term()} | :error | {:error, term()}
  def get_global_by_key_in_tx(repo, key) when is_atom(repo) and is_binary(key) do
    with {:ok, registered} <- Registry.require_key(key) do
      case repo.get_by(AppConfig, scope: @global_scope, key: key) do
        %AppConfig{value: envelope} ->
          case Codec.load(registered, @global_scope, key, envelope) do
            {:ok, value} -> {:ok, value}
            {:error, reason} -> {:error, {:storage_error, @global_scope, key, reason}}
          end

        nil ->
          :error
      end
    end
  end

  @doc false
  @spec put_global_by_key_in_tx(module(), String.t(), term()) ::
          {:ok, committed_write()} | {:error, term()}
  def put_global_by_key_in_tx(repo, key, value) when is_atom(repo) and is_binary(key) do
    with {:ok, registered} <- Registry.require_key(key) do
      put_row(repo, @global_scope, key, registered, value)
    end
  end

  @doc false
  @spec cache_committed_write(committed_write()) :: {:ok, term()}
  def cache_committed_write({parsed, scope, key}) do
    refresh_cache_after_commit(scope, key)
    {:ok, parsed}
  end

  @doc """
  Stores a validated agent-specific override for an exact definition.

  Agent values never change the key path. The agent id only selects the
  `agent:<id>` scope so global and agent values keep the same logical key.
  """
  @spec put_for_agent(String.t(), Definition.t(), term()) :: {:ok, term()} | {:error, term()}
  def put_for_agent(agent_id, %Definition{} = definition, value) do
    with {:ok, scope} <- agent_scope(agent_id),
         {:ok, registered} <- Registry.require_definition(definition),
         :ok <- ensure_scope(registered, scope) do
      put(scope, registered.key, registered, value)
    end
  end

  @doc """
  Stores a validated agent-specific override for a concrete exact or pattern-backed key.
  """
  @spec put_for_agent_by_key(String.t(), String.t(), term()) :: {:ok, term()} | {:error, term()}
  def put_for_agent_by_key(agent_id, key, value) when is_binary(key) do
    with {:ok, scope} <- agent_scope(agent_id),
         {:ok, registered} <- Registry.require_key(key),
         :ok <- ensure_scope(registered, scope) do
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
         {:ok, registered} <- Registry.require_definition(definition),
         :ok <- ensure_scope(registered, scope) do
      delete(scope, registered.key)
    end
  end

  @doc """
  Deletes the agent-specific row for a concrete exact or pattern-backed key.
  """
  @spec delete_for_agent_by_key(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_for_agent_by_key(agent_id, key) when is_binary(key) do
    with {:ok, scope} <- agent_scope(agent_id),
         {:ok, registered} <- Registry.require_key(key),
         :ok <- ensure_scope(registered, scope) do
      delete(scope, key)
    end
  end

  @doc """
  Lists AppConfigure entries that the console may display.

  Exact definitions are always listed. Pattern definitions are listed as
  read-only policy rows, while concrete pattern keys are listed only when a
  global row already exists and matches exactly one registered pattern.
  """
  @spec list_console_items() :: {:ok, [console_item()]} | {:error, term()}
  def list_console_items do
    rows_by_key = global_rows_by_key()
    exact_keys = Registry.list_definitions() |> MapSet.new(& &1.key)

    exact_items =
      Registry.list_definitions()
      |> Enum.map(&console_definition_item(&1, Map.get(rows_by_key, &1.key), :exact))

    pattern_policy_items =
      Registry.list_patterns()
      |> Enum.map(&console_pattern_policy_item/1)

    concrete_pattern_items =
      rows_by_key
      |> Enum.reject(fn {key, _row} -> MapSet.member?(exact_keys, key) end)
      |> Enum.flat_map(&console_concrete_pattern_item/1)

    {:ok, exact_items ++ pattern_policy_items ++ concrete_pattern_items}
  end

  @doc """
  Returns one console-visible AppConfigure detail projection.
  """
  @spec console_detail_by_key(String.t()) :: {:ok, console_item()} | {:error, term()}
  def console_detail_by_key(key) when is_binary(key) do
    with {:ok, {kind, definition}} <- console_definition(key) do
      {:ok, console_definition_item(definition, global_row(key), kind, key)}
    end
  end

  @doc """
  Stores one console-editable global value.
  """
  @spec console_put_global_by_key(String.t(), term()) :: {:ok, console_item()} | {:error, term()}
  def console_put_global_by_key(key, value) when is_binary(key) do
    with {:ok, {_kind, _definition}} <- writable_console_definition(key),
         {:ok, _value} <- put_global_by_key(key, value) do
      console_detail_by_key(key)
    end
  end

  @doc """
  Applies one console update, preserving a present encrypted value when the
  request intentionally omits `value`.

  Missing values stay invalid for plaintext or unset configuration so an empty
  request cannot accidentally look like a successful write.
  """
  @spec console_update_global_by_key(String.t(), map()) ::
          {:ok, console_item()} | {:error, term()}
  def console_update_global_by_key(key, attrs) when is_binary(key) and is_map(attrs) do
    case fetch_console_update_value(attrs) do
      {:ok, value} ->
        console_put_global_by_key(key, value)

      :error ->
        with {:ok, {_kind, _definition}} <- writable_console_definition(key) do
          preserve_encrypted_console_value(key)
        end
    end
  end

  @doc """
  Deletes one console-editable global value so normal resolution falls back.
  """
  @spec console_delete_global_by_key(String.t()) :: {:ok, console_item()} | {:error, term()}
  def console_delete_global_by_key(key) when is_binary(key) do
    with {:ok, {kind, definition}} <- writable_console_definition(key),
         :ok <- delete_global_by_key(key) do
      deleted_console_item(kind, definition, key)
    end
  end

  @doc """
  Reveals one encrypted console-editable value on demand.
  """
  @spec console_decrypt_by_key(String.t()) :: {:ok, term()} | {:error, term()}
  def console_decrypt_by_key(key) when is_binary(key) do
    with {:ok, {_kind, %{encrypted: true}}} <- console_definition(key),
         {:ok, value} <- get_by_key(key) do
      {:ok, value}
    else
      {:ok, {_kind, %{encrypted: false}}} -> {:error, :not_encrypted}
      :error -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_console_update_value(attrs) do
    case Map.fetch(attrs, "value") do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, :value)
    end
  end

  defp preserve_encrypted_console_value(key) do
    with {:ok, %{encrypted: true, present: true} = item} <- console_detail_by_key(key) do
      {:ok, item}
    else
      {:ok, _item} -> {:error, :missing_value}
      {:error, _reason} = error -> error
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

  defp resolution_scopes(%{scope: :global}, _opts), do: [@global_scope]

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

  defp resolve_scopes_in_tx({:error, reason}, _repo, _definition, _key),
    do: {:error, reason}

  defp resolve_scopes_in_tx(scopes, repo, definition, key) do
    scopes
    |> Enum.reduce_while(:error, fn scope, :error ->
      case repo.get_by(AppConfig, scope: scope, key: key) do
        %AppConfig{value: envelope} ->
          result =
            case Codec.load(definition, scope, key, envelope) do
              {:ok, value} ->
                {:ok, %Resolution{value: value, source: source_for_scope(scope), scope: scope}}

              {:error, reason} ->
                {:error, {:storage_error, scope, key, reason}}
            end

          {:halt, result}

        nil ->
          {:cont, :error}
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
    with {:ok, committed_write} <- put_row(Repo, scope, key, definition, value) do
      cache_committed_write(committed_write)
    end
  end

  defp put_row(repo, scope, key, definition, value) do
    with :ok <- ensure_scope(definition, scope),
         {:ok, envelope, parsed} <- Codec.dump(definition, scope, key, value),
         :ok <- upsert_row(repo, scope, key, envelope) do
      {:ok, {parsed, scope, key}}
    end
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

    refresh_cache_after_commit(scope, key)
    :ok
  end

  defp refresh_cache_after_commit(scope, key) do
    result =
      try do
        with {:ok, state} <- Cache.load(scope, key),
             :ok <- validate_refreshed_state(scope, key, state) do
          :ok
        end
      catch
        :exit, reason -> {:error, {:cache_unavailable, reason}}
      end

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "app_configure.cache.after_commit_refresh_failed",
          "app configure commit succeeded but cache refresh failed",
          %{scope: scope, key: key, reason: inspect(reason)}
        )
    end
  end

  defp lock_global_key(repo, key) do
    lock_key = "app_configure:#{@global_scope}:#{key}"

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_global_value_in_tx(repo, definition) do
    case get_global_by_key_in_tx(repo, definition.key) do
      {:ok, value} -> {:ok, value}
      :error -> definition_default(definition)
      {:error, _reason} = error -> error
    end
  end

  defp definition_default(%{default?: true, default_value: value}), do: {:ok, value}

  defp definition_default(definition),
    do: {:error, {:missing_global_value, definition_key(definition)}}

  defp run_global_updater(updater, current) do
    case updater.(current) do
      {:ok, _value} = result -> result
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_global_update_result, other}}
    end
  end

  defp validate_refreshed_state(scope, key, {:row, envelope}) do
    with {:ok, definition} <- Registry.require_key(key) do
      case Codec.load(definition, scope, key, envelope) do
        {:ok, _value} ->
          :ok

        {:error, reason} ->
          {:error, {:storage_error, scope, key, reason}}
      end
    end
  end

  defp validate_refreshed_state(_scope, _key, :absent), do: :ok
  defp validate_refreshed_state(_scope, _key, {:error, reason}), do: {:error, reason}

  defp definition_key(%Definition{key: key}), do: key
  defp definition_key(%PatternDefinition{id: id}), do: id

  defp ensure_scope(%{scope: :global} = definition, scope) when scope != @global_scope,
    do: {:error, {:global_scope_only, definition_key(definition)}}

  defp ensure_scope(_definition, _scope), do: :ok

  defp console_definition(key) do
    case Registry.classify_key(key) do
      {:ok, {:exact, definition}} ->
        {:ok, {:exact, definition}}

      {:ok, {:pattern, pattern}} ->
        case global_row(key) do
          %AppConfig{} -> {:ok, {:pattern_concrete, pattern}}
          nil -> {:error, {:pattern_key_not_editable, key}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp writable_console_definition(key) do
    case Registry.classify_key(key) do
      {:ok, {:exact, %Definition{console_writable: false}}} ->
        {:error, {:key_managed_by_owner, key}}

      {:ok, {:exact, definition}} ->
        {:ok, {:exact, definition}}

      {:ok, {:pattern, %PatternDefinition{console_writable: false}}} ->
        {:error, {:key_managed_by_owner, key}}

      {:ok, {:pattern, pattern}} ->
        case global_row(key) do
          %AppConfig{} -> {:ok, {:pattern_concrete, pattern}}
          nil -> {:error, {:pattern_key_not_editable, key}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp console_definition_item(definition, row, kind, runtime_key \\ nil)

  defp console_definition_item(%Definition{} = definition, row, :exact, _runtime_key) do
    key = definition.key

    %{
      key: key,
      kind: "exact",
      description: definition.description,
      encrypted: definition.encrypted,
      scope: Atom.to_string(definition.scope),
      editable: definition.console_writable,
      default_present: definition.default?,
      overridden: not is_nil(row)
    }
    |> Map.merge(value_projection(definition, key, row))
  end

  defp console_definition_item(
         %PatternDefinition{} = definition,
         row,
         :pattern_concrete,
         runtime_key
       ) do
    key = runtime_key || definition.id

    %{
      key: key,
      kind: "pattern_concrete",
      pattern_id: definition.id,
      description: definition.description,
      encrypted: definition.encrypted,
      scope: Atom.to_string(definition.scope),
      editable: definition.console_writable,
      default_present: definition.default?,
      overridden: not is_nil(row)
    }
    |> Map.merge(value_projection(definition, key, row))
  end

  defp console_pattern_policy_item(%PatternDefinition{} = pattern) do
    %{
      key: pattern.id,
      kind: "pattern",
      pattern: Regex.source(pattern.key_pattern),
      description: pattern.description,
      encrypted: pattern.encrypted,
      scope: Atom.to_string(pattern.scope),
      editable: false,
      default_present: pattern.default?,
      overridden: false,
      present: pattern.default?,
      source: "pattern"
    }
  end

  defp console_concrete_pattern_item({key, %AppConfig{} = row}) do
    case Registry.classify_key(key) do
      {:ok, {:pattern, pattern}} ->
        [console_definition_item(pattern, row, :pattern_concrete, key)]

      _not_console_editable ->
        []
    end
  end

  defp deleted_console_item(:exact, _definition, key), do: console_detail_by_key(key)

  defp deleted_console_item(:pattern_concrete, %PatternDefinition{} = definition, key) do
    item =
      definition
      |> console_definition_item(nil, :pattern_concrete, key)
      |> Map.put(:editable, false)
      |> Map.put(:overridden, false)

    {:ok, item}
  end

  defp value_projection(%{encrypted: true} = definition, _key, row) do
    %{
      present: not is_nil(row) or definition.default?,
      source: encrypted_source(definition, row)
    }
  end

  defp value_projection(%{encrypted: false}, key, _row) do
    case resolve_by_key(key) do
      {:ok, %Resolution{value: value, source: source}} ->
        %{present: true, source: Atom.to_string(source), value: value}

      :error ->
        %{present: false, source: "missing", value: nil}

      {:error, reason} ->
        %{present: false, source: "error", error: inspect(reason), value: nil}
    end
  end

  defp encrypted_source(_definition, %AppConfig{}), do: "global"
  defp encrypted_source(%{default?: true}, nil), do: "default"
  defp encrypted_source(_definition, nil), do: "missing"

  defp global_rows_by_key do
    AppConfig
    |> where([row], row.scope == ^@global_scope)
    |> Repo.all()
    |> Map.new(&{&1.key, &1})
  end

  defp global_row(key) do
    AppConfig
    |> where([row], row.scope == ^@global_scope and row.key == ^key)
    |> Repo.one()
  end

  defp agent_scope(agent_id) when is_binary(agent_id) and agent_id != "" do
    {:ok, @agent_scope_prefix <> agent_id}
  end

  defp agent_scope(_agent_id), do: {:error, :invalid_agent_id}

  defp source_for_scope(@global_scope), do: :global
  defp source_for_scope(@agent_scope_prefix <> _agent_id), do: :agent
end
