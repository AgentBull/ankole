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
  @tenant_scope_prefix "tenant:"
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

  @doc false
  @spec replace_declarations(atom(), [Definition.t()], [PatternDefinition.t()]) ::
          :ok | {:error, term()}
  def replace_declarations(source, definitions, patterns)
      when is_atom(source) and is_list(definitions) and is_list(patterns) do
    Registry.replace_declarations(source, definitions, patterns)
  end

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

  Tenant keys resolve the selected Agent value, the tenant value, the global
  value, then the code default. Site keys start at global. Only missing rows
  fall back; invalid rows return a storage error.
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
  to know whether it came from tenant, global, or default scope.
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
    case Repo.transact(fn repo -> update_global_in_tx(repo, definition, updater) end) do
      {:ok, committed_write} -> cache_committed_write(committed_write)
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec update_global_in_tx(module(), Definition.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, committed_write()} | {:error, term()}
  def update_global_in_tx(repo, %Definition{} = definition, updater)
      when is_atom(repo) and is_function(updater, 1) do
    with {:ok, registered} <- Registry.require_definition(definition),
         :ok <- lock_global_key(repo, registered.key),
         {:ok, current} <- current_global_value_in_tx(repo, registered),
         {:ok, next_value} <- run_global_updater(updater, current) do
      put_row(repo, @global_scope, registered.key, registered, next_value)
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
      case repo.get_by(AppConfig.for_scope(@global_scope), scope: @global_scope, key: key) do
        %{value: envelope} ->
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

  @doc "Stores an override for an Agent in the current tenant."
  @spec put_for_agent(String.t(), Definition.t(), term()) :: {:ok, term()} | {:error, term()}
  def put_for_agent(agent_uid, %Definition{} = definition, value) do
    with {:ok, scope} <- agent_scope(agent_uid),
         {:ok, registered} <- Registry.require_definition(definition) do
      put(scope, registered.key, registered, value)
    end
  end

  @doc "Stores an Agent override for one declared concrete key."
  @spec put_for_agent_by_key(String.t(), String.t(), term()) :: {:ok, term()} | {:error, term()}
  def put_for_agent_by_key(agent_uid, key, value) when is_binary(key) do
    with {:ok, scope} <- agent_scope(agent_uid),
         {:ok, registered} <- Registry.require_key(key) do
      put(scope, key, registered, value)
    end
  end

  @doc "Deletes an Agent override so resolution uses the tenant, global, or default value."
  @spec delete_for_agent(String.t(), Definition.t()) :: :ok | {:error, term()}
  def delete_for_agent(agent_uid, %Definition{} = definition),
    do: delete_for_agent_by_key(agent_uid, definition.key)

  @doc "Deletes one declared concrete key from an Agent's overrides."
  @spec delete_for_agent_by_key(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_for_agent_by_key(agent_uid, key) when is_binary(key) do
    with {:ok, scope} <- agent_scope(agent_uid),
         {:ok, registered} <- Registry.require_key(key),
         :ok <- ensure_scope(registered, scope) do
      delete(scope, key)
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
  Lists the AppConfigure entries that the console may display in one scope.

  Exact definitions are always listed. Pattern definitions are listed as
  read-only policy rows. A concrete pattern key is listed when a row exists
  for it in this scope or, for a tenant, in the global scope it inherits.
  """
  @spec list_console_items(:global | :tenant) :: {:ok, [console_item()]}
  def list_console_items(scope) do
    rows = scope_rows(scope)
    inherited = if scope == :tenant, do: scope_rows(:global), else: %{}
    definitions = Registry.list_definitions()
    exact_keys = MapSet.new(definitions, & &1.key)

    exact = Enum.map(definitions, &console_item(scope, &1, :exact, &1.key, rows[&1.key]))
    patterns = Enum.map(Registry.list_patterns(), &console_pattern_policy_item/1)

    concrete =
      for {key, _row} <- Map.merge(inherited, rows),
          not MapSet.member?(exact_keys, key),
          {:ok, {:pattern_concrete, pattern}} <- [console_definition(scope, key)],
          do: console_item(scope, pattern, :pattern_concrete, key, rows[key])

    {:ok, exact ++ patterns ++ concrete}
  end

  @doc "Returns one console-visible AppConfigure entry of one scope."
  @spec console_detail(:global | :tenant, String.t()) :: {:ok, console_item()} | {:error, term()}
  def console_detail(scope, key) when is_binary(key) do
    with {:ok, {kind, definition}} <- console_definition(scope, key),
         do: {:ok, console_item(scope, definition, kind, key, scope_row(scope, key))}
  end

  @doc """
  Applies one console update. A request that omits `value` keeps an encrypted
  value stored in this scope; otherwise it is invalid, so an empty request
  cannot look like a successful write.
  """
  @spec console_update(:global | :tenant, String.t(), map()) ::
          {:ok, console_item()} | {:error, term()}
  def console_update(scope, key, attrs) when is_binary(key) and is_map(attrs) do
    with {:ok, {_kind, definition}} <- writable_console_definition(scope, key) do
      case fetch_console_update_value(attrs) do
        {:ok, value} ->
          with {:ok, _value} <- put_scope_value(scope, key, value),
               do: console_detail(scope, key)

        :error ->
          if definition.encrypted and scope_row(scope, key),
            do: console_detail(scope, key),
            else: {:error, :missing_value}
      end
    end
  end

  @doc "Deletes one console-editable value so normal resolution falls back."
  @spec console_delete(:global | :tenant, String.t()) :: {:ok, console_item()} | {:error, term()}
  def console_delete(scope, key) when is_binary(key) do
    with {:ok, {kind, definition}} <- writable_console_definition(scope, key),
         :ok <- delete_scope_value(scope, key),
         do: {:ok, console_item(scope, definition, kind, key, nil)}
  end

  @doc "Reveals one encrypted console-visible value on demand."
  @spec console_decrypt(:global | :tenant, String.t()) :: {:ok, term()} | {:error, term()}
  def console_decrypt(scope, key) when is_binary(key) do
    with {:ok, {_kind, %{encrypted: true}}} <- console_definition(scope, key),
         {:ok, value} <- get_by_key(key, resolution_opts(scope)) do
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

  defp put_scope_value(:global, key, value), do: put_global_by_key(key, value)
  defp put_scope_value(:tenant, key, value), do: put_tenant_by_key(key, value)
  defp delete_scope_value(:global, key), do: delete_global_by_key(key)
  defp delete_scope_value(:tenant, key), do: delete_tenant_by_key(key)
  defp resolution_opts(:global), do: [scope: :global]
  defp resolution_opts(:tenant), do: []
  defp storage_scope(:global), do: @global_scope
  defp storage_scope(:tenant), do: tenant_scope()

  defp scope_rows(scope) do
    AppConfig.for_scope(storage_scope(scope))
    |> where([row], row.scope == ^storage_scope(scope))
    |> Repo.all()
    |> Map.new(&{&1.key, &1})
  end

  defp scope_row(scope, key),
    do:
      Repo.get_by(AppConfig.for_scope(storage_scope(scope)),
        scope: storage_scope(scope),
        key: key
      )

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
    cond do
      Keyword.get(opts, :scope) == :global ->
        [@global_scope]

      Keyword.has_key?(opts, :agent_id) ->
        with {:ok, scope} <- agent_scope(Keyword.fetch!(opts, :agent_id)),
             do: [scope, tenant_scope(), @global_scope]

      true ->
        [tenant_scope(), @global_scope]
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
      case repo.get_by(AppConfig.for_scope(scope), scope: scope, key: key) do
        %{value: envelope} ->
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

    schema = AppConfig.for_scope(scope)

    row =
      if scope == @global_scope,
        do: struct!(schema),
        else: struct!(schema, tenant_id: scope_tenant_id(scope))

    changeset =
      schema.changeset(row, %{
        scope: scope,
        key: key,
        value: envelope,
        inserted_at: now,
        updated_at: now
      })

    case repo.insert(changeset,
           on_conflict: [set: [value: envelope, updated_at: now]],
           conflict_target:
             if(scope == @global_scope, do: [:scope, :key], else: [:tenant_id, :scope, :key])
         ) do
      {:ok, _row} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp delete(scope, key) do
    AppConfig.for_scope(scope)
    |> where([row], row.scope == ^scope and row.key == ^key)
    |> Repo.delete_all()

    refresh_cache_after_commit(scope, key)
    :ok
  end

  defp refresh_cache_after_commit(scope, key) do
    result =
      try do
        with {:ok, state} <- Cache.refresh(scope, key),
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

  # A tenant does not see a global-scope pattern that its owner manages. A
  # concrete pattern key is visible while a row backs it.
  defp console_definition(scope, key) do
    case Registry.classify_key(key) do
      {:ok, {:exact, definition}} ->
        {:ok, {:exact, definition}}

      {:ok, {:pattern, %PatternDefinition{scope: :global, console_writable: false}}}
      when scope == :tenant ->
        {:error, {:key_managed_by_owner, key}}

      {:ok, {:pattern, pattern}} ->
        if scope_row(scope, key) || (scope == :tenant && scope_row(:global, key)),
          do: {:ok, {:pattern_concrete, pattern}},
          else: {:error, {:pattern_key_not_editable, key}}

      {:error, _reason} = error ->
        error
    end
  end

  defp writable_console_definition(scope, key) do
    with {:ok, {_kind, definition}} <- Registry.classify_key(key),
         true <- definition.console_writable,
         :ok <- ensure_scope(definition, storage_scope(scope)) do
      console_definition(scope, key)
    else
      false -> {:error, {:key_managed_by_owner, key}}
      error -> error
    end
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

  # A global-scope key is read-only in a tenant, and a concrete pattern key is
  # editable only while a row backs it. An encrypted value reports where it
  # comes from without decrypting it.
  defp console_item(scope, definition, kind, key, row) do
    item =
      %{
        key: key,
        kind: Atom.to_string(kind),
        description: definition.description,
        encrypted: definition.encrypted,
        scope: Atom.to_string(definition.scope),
        editable:
          definition.console_writable and (scope == :global or definition.scope != :global) and
            (kind == :exact or not is_nil(row) or
               (scope == :tenant and not is_nil(scope_row(:global, key)))),
        default_present: definition.default?,
        overridden: not is_nil(row)
      }
      |> then(
        &if(kind == :pattern_concrete, do: Map.put(&1, :pattern_id, definition.id), else: &1)
      )

    if definition.encrypted do
      Map.merge(item, encrypted_source(scope, definition, key, row))
    else
      case resolve_by_key(key, resolution_opts(scope)) do
        {:ok, %Resolution{value: value, source: source}} ->
          Map.merge(item, %{present: true, source: Atom.to_string(source), value: value})

        :error ->
          Map.merge(item, %{present: false, source: "missing", value: nil})

        {:error, reason} ->
          Map.merge(item, %{present: false, source: "error", error: inspect(reason), value: nil})
      end
    end
  end

  defp encrypted_source(scope, definition, key, row) do
    source =
      cond do
        row -> Atom.to_string(scope)
        scope == :tenant and scope_row(:global, key) -> "global"
        definition.default? -> "default"
        true -> "missing"
      end

    %{present: source != "missing", source: source}
  end

  def update_tenant_in_tx(repo, %Definition{} = definition, updater) do
    scope = tenant_scope()

    with {:ok, registered} <- Registry.require_definition(definition),
         :ok <- ensure_scope(registered, scope),
         {:ok, _} <-
           SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
             "app_configure:#{scope}:#{registered.key}"
           ]),
         {:ok, current} <- get_tenant_by_key_in_tx(repo, registered.key),
         {:ok, next} <- run_global_updater(updater, current) do
      put_row(repo, scope, registered.key, registered, next)
    end
  end

  def update_tenant(%Definition{} = definition, updater) do
    case Repo.transact(fn repo -> update_tenant_in_tx(repo, definition, updater) end) do
      {:ok, write} -> cache_committed_write(write)
      error -> error
    end
  end

  defp tenant_scope, do: @tenant_scope_prefix <> Repo.tenant_id!()
  defp scope_tenant_id(@global_scope), do: nil
  defp scope_tenant_id(@tenant_scope_prefix <> tenant_id), do: tenant_id
  defp scope_tenant_id(@agent_scope_prefix <> _), do: Repo.tenant_id!()

  defp agent_scope(agent_uid) when is_binary(agent_uid) and agent_uid != "" do
    case Ankole.Principals.get_agent(agent_uid) do
      {:ok, _agent} -> {:ok, @agent_scope_prefix <> agent_uid}
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp agent_scope(_agent_uid), do: {:error, :invalid_agent_id}

  def put_tenant_by_key(key, value) do
    with {:ok, definition} <- Registry.require_key(key) do
      put(tenant_scope(), key, definition, value)
    end
  end

  def put_tenant_by_key_in_tx(repo, key, value) do
    with {:ok, definition} <- Registry.require_key(key) do
      put_row(repo, tenant_scope(), key, definition, value)
    end
  end

  def get_tenant_by_key_in_tx(repo, key) do
    with {:ok, definition} <- Registry.require_key(key) do
      definition
      |> resolution_scopes([])
      |> resolve_scopes_in_tx(repo, definition, key)
      |> value_result()
    end
  end

  def delete_tenant_by_key(key) do
    with {:ok, definition} <- Registry.require_key(key),
         :ok <- ensure_scope(definition, tenant_scope()) do
      delete(tenant_scope(), key)
    end
  end

  defp source_for_scope(@global_scope), do: :global
  defp source_for_scope(@tenant_scope_prefix <> _), do: :tenant
  defp source_for_scope(@agent_scope_prefix <> _), do: :agent
end
