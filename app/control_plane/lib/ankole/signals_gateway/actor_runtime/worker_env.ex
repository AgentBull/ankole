defmodule Ankole.SignalsGateway.ActorRuntime.WorkerEnv do
  @moduledoc """
  Operator-managed environment variables for Agent Computer shells.

  Three tracks feed one merged environment:

    * Declared variables are AppConfigure definitions marked with
      `worker_env_name`. Schema, encryption, description, and per-agent
      overrides stay with AppConfigure; this module only projects the resolved
      value into the shell environment. Marked definitions must be registered
      at boot, not lazily, or enumeration misses them.
    * Custom variables are free-form operator rows in
      `agent_computer_worker_envs`, global or per agent, with a per-row
      secret flag.
    * Binding-derived variables are resolved by active signal adapters for the
      current Agent. They are ephemeral and never become editable Console rows.

  Merge order (low to high): declared < custom global < custom agent <
  binding-derived < the model's explicit per-command `env`. Provider-derived
  identity wins over operator rows, while the trusted model still has the last
  word for a single command.

  Console reads and writes route by name so operators see one editing
  surface: a name resolves to its custom row first (matching merge
  precedence), then to its declared definition, and otherwise creates a
  custom row.
  """

  import Ecto.Query

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Resolution
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv.Crypto
  alias Ankole.SignalsGateway.ActorRuntime.WorkerEnv.EnvVar
  alias Ankole.SignalsGateway.ActorRuntime.BindingWorkerEnv

  @global_scope "global"
  @agent_scope_prefix "agent:"
  @name_format ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  # Variables the sandbox bootstrap or worker identity owns. Overriding them
  # from operator rows would not restrict the model (it can re-export inside
  # the shell); it would only break the sandbox contract in confusing ways.
  @reserved_names ~w(PATH HOME SHELL TERM LANG BASH_ENV ENV WORKER_ID DATABASE_URL CODEX_UNSAFE_ALLOW_NO_SANDBOX)
  @reserved_prefix "ANKOLE_"

  @type console_item :: map()

  @doc """
  Computes the merged shell environment for one agent.

  Secret values are decrypted here because the result stays on the ephemeral
  RPC path to the worker; nothing durable stores the flat map. A declared key
  that resolves to a non-string, non-nil value is a declaration bug and fails
  loudly instead of exporting garbage into shells.
  """
  @spec effective_env(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def effective_env(agent_uid) do
    with {:ok, %{operator: operator, binding: binding}} <- effective_env_parts(agent_uid) do
      {:ok, Map.merge(operator, binding)}
    end
  end

  @doc "Returns operator and binding variables without losing their ownership boundary."
  @spec effective_env_parts(String.t()) ::
          {:ok, %{operator: %{String.t() => String.t()}, binding: %{String.t() => String.t()}}}
          | {:error, term()}
  def effective_env_parts(agent_uid) do
    with {:ok, scope} <- agent_scope(agent_uid),
         {:ok, declared} <- declared_env(agent_uid),
         {:ok, global_custom} <- custom_env(@global_scope),
         {:ok, agent_custom} <- custom_env(scope),
         {:ok, binding_derived} <- BindingWorkerEnv.resolve(agent_uid) do
      {:ok,
       %{
         operator: declared |> Map.merge(global_custom) |> Map.merge(agent_custom),
         binding: binding_derived
       }}
    end
  end

  @doc "Builds the non-secret WorkerEnv part of a BackgroundAgentJob runtime projection."
  @spec runtime_projection(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def runtime_projection(agent_uid, opts \\ []) do
    with {:ok, items} <- console_list_for_agent(agent_uid, opts) do
      present = Enum.filter(items, &(&1.present == true))

      plain_values =
        present
        |> Enum.reject(& &1.secret)
        |> Map.new(fn item -> {item.name, Map.fetch!(item, :value)} end)

      {:ok,
       %{
         "names" => present |> Enum.map(& &1.name) |> Enum.sort(),
         "plain_values" => plain_values
       }}
    end
  end

  @doc """
  Lists the installation-wide console view: custom global rows plus declared
  definitions resolved at global scope, one item per variable name.
  """
  @spec console_list_global() :: {:ok, [console_item()]}
  def console_list_global do
    custom_by_name = rows_by_name(@global_scope)

    custom_items =
      custom_by_name
      |> Map.values()
      |> Enum.map(&custom_item(&1, "global"))

    declared_items =
      declared_definitions()
      |> Enum.reject(&Map.has_key?(custom_by_name, &1.worker_env_name))
      |> Enum.map(&declared_item(&1, nil))

    {:ok, Enum.sort_by(custom_items ++ declared_items, & &1.name)}
  end

  @doc """
  Lists the effective console view for one agent with per-item provenance.

  Custom rows win over declared definitions per name, and agent rows win over
  global rows, mirroring `effective_env/1` so the console never shows a value
  the shell would not see.
  """
  @spec console_list_for_agent(String.t(), keyword()) ::
          {:ok, [console_item()]} | {:error, term()}
  def console_list_for_agent(agent_uid, opts \\ []) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid) do
      agent_rows = rows_by_name(scope)
      global_rows = rows_by_name(@global_scope)

      custom_items =
        global_rows
        |> Map.merge(agent_rows)
        |> Map.values()
        |> Enum.map(&custom_item(&1, custom_source(&1)))

      custom_names = MapSet.new(custom_items, & &1.name)

      declared_items =
        declared_definitions()
        |> Enum.reject(&MapSet.member?(custom_names, &1.worker_env_name))
        |> Enum.map(&declared_item(&1, agent_uid, opts))

      {:ok, Enum.sort_by(custom_items ++ declared_items, & &1.name)}
    end
  end

  @doc """
  Reads one installation-wide console item by variable name.
  """
  @spec console_detail_global(String.t()) :: {:ok, console_item()} | {:error, term()}
  def console_detail_global(name) do
    with :ok <- validate_name(name) do
      case route(@global_scope, name) do
        {:custom, row} -> {:ok, custom_item(row, "global")}
        {:declared, definition} -> {:ok, declared_item(definition, nil)}
        :unknown -> {:error, :not_found}
      end
    end
  end

  @doc """
  Reads one effective console item for an agent by variable name.
  """
  @spec console_detail_for_agent(String.t(), String.t()) ::
          {:ok, console_item()} | {:error, term()}
  def console_detail_for_agent(agent_uid, name) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid),
         :ok <- validate_name(name) do
      case route_for_agent(scope, name) do
        {:custom, row} -> {:ok, custom_item(row, custom_source(row))}
        {:declared, definition} -> {:ok, declared_item(definition, agent_uid)}
        :unknown -> {:error, :not_found}
      end
    end
  end

  @doc """
  Stores one installation-wide value by name.

  Declared names validate through their AppConfigure definition (any JSON
  value the schema accepts); custom names require a string for creation or
  replacement and accept an optional `secret` flag and `description`. A
  present encrypted value may be omitted to preserve its stored ciphertext.
  """
  @spec console_put_global(String.t(), map()) :: {:ok, console_item()} | {:error, term()}
  def console_put_global(name, attrs) when is_map(attrs) do
    with :ok <- validate_name(name) do
      case route(@global_scope, name) do
        {:custom, row} -> upsert_custom(@global_scope, name, attrs, row)
        {:declared, definition} -> put_declared_global(definition, attrs)
        :unknown -> upsert_custom(@global_scope, name, attrs, nil)
      end
    end
  end

  @doc """
  Stores one agent-tier value by name.

  For declared names this writes the AppConfigure `agent:<uid>` override; for
  custom names it writes an agent row that wins over the global row of the
  same name. An existing encrypted agent value may be omitted to preserve it.
  """
  @spec console_put_for_agent(String.t(), String.t(), map()) ::
          {:ok, console_item()} | {:error, term()}
  def console_put_for_agent(agent_uid, name, attrs) when is_map(attrs) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid),
         :ok <- validate_name(name) do
      case route(scope, name) do
        {:custom, row} ->
          upsert_custom(scope, name, attrs, row)

        {:declared, definition} ->
          put_declared_for_agent(agent_uid, definition, attrs)

        :unknown ->
          upsert_custom(scope, name, attrs, nil)
      end
    end
  end

  @doc """
  Deletes the installation-wide value for one name.

  Declared names fall back to their code default after deletion; custom rows
  are removed entirely.
  """
  @spec console_delete_global(String.t()) :: {:ok, console_item()} | {:error, term()}
  def console_delete_global(name) do
    with :ok <- validate_name(name) do
      case route(@global_scope, name) do
        {:custom, row} ->
          delete_row(row)
          deleted_detail_global(name)

        {:declared, definition} ->
          with :ok <- AppConfigure.delete_global_by_key(definition.key) do
            {:ok, declared_item(definition, nil)}
          end

        :unknown ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Deletes the agent-tier value for one name.

  Only the agent tier is removed: a custom global row or a declared global
  value stays effective for the agent afterwards.
  """
  @spec console_delete_for_agent(String.t(), String.t()) ::
          {:ok, console_item()} | {:error, term()}
  def console_delete_for_agent(agent_uid, name) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid),
         :ok <- validate_name(name) do
      case route(scope, name) do
        {:custom, row} ->
          delete_row(row)
          deleted_detail_for_agent(agent_uid, name)

        {:declared, definition} ->
          with :ok <- AppConfigure.delete_for_agent_by_key(agent_uid, definition.key) do
            {:ok, declared_item(definition, agent_uid)}
          end

        :unknown ->
          {:error, :not_found}
      end
    end
  end

  @doc """
  Reveals one encrypted installation-wide value on demand.
  """
  @spec console_decrypt_global(String.t()) :: {:ok, term()} | {:error, term()}
  def console_decrypt_global(name) do
    with :ok <- validate_name(name) do
      case route(@global_scope, name) do
        {:custom, row} -> decrypt_row(row)
        {:declared, definition} -> decrypt_declared(definition, nil)
        :unknown -> {:error, :not_found}
      end
    end
  end

  @doc """
  Reveals the encrypted value effective for one agent on demand.
  """
  @spec console_decrypt_for_agent(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def console_decrypt_for_agent(agent_uid, name) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid),
         :ok <- validate_name(name) do
      case route_for_agent(scope, name) do
        {:custom, row} -> decrypt_row(row)
        {:declared, definition} -> decrypt_declared(definition, agent_uid)
        :unknown -> {:error, :not_found}
      end
    end
  end

  @doc """
  Validates a shell variable name against syntax and the reserved list.
  """
  @spec validate_name(term()) :: :ok | {:error, term()}
  def validate_name(name) when is_binary(name) do
    cond do
      not Regex.match?(@name_format, name) -> {:error, {:invalid_worker_env_name, name}}
      reserved_name?(name) -> {:error, {:reserved_worker_env_name, name}}
      true -> :ok
    end
  end

  def validate_name(name), do: {:error, {:invalid_worker_env_name, name}}

  @doc """
  Returns whether a name belongs to the sandbox bootstrap or worker identity.
  """
  @spec reserved_name?(String.t()) :: boolean()
  def reserved_name?(name) when is_binary(name) do
    name in @reserved_names or String.starts_with?(name, @reserved_prefix)
  end

  @doc """
  Returns exact operator-configured secret values for one Agent.

  Declared and custom variables carry explicit encryption metadata, so this
  reads only AppConfigure and the custom variable table. Binding-derived
  provider tokens are outside this set. They are short-lived credentials that
  the adapter mints for the Worker shell, and resolving them here would make an
  unrelated caller depend on provider health.
  """
  @spec sensitive_values(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def sensitive_values(agent_uid) do
    with {:ok, scope} <- agent_scope(agent_uid),
         {:ok, declared} <- declared_sensitive_values(agent_uid),
         {:ok, global_custom} <- custom_sensitive_values(@global_scope),
         {:ok, agent_custom} <- custom_sensitive_values(scope) do
      {:ok,
       (declared ++ global_custom ++ agent_custom)
       |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
       |> Enum.uniq()}
    end
  end

  # ---- declared track ----

  defp declared_definitions do
    AppConfigure.list_definitions()
    |> Enum.filter(& &1.worker_env_name)
  end

  defp declared_env(agent_uid) do
    declared_definitions()
    |> Enum.reduce_while({:ok, %{}}, fn definition, {:ok, acc} ->
      case declared_value(definition, agent_uid) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, Map.put(acc, definition.worker_env_name, value)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp declared_sensitive_values(agent_uid) do
    declared_definitions()
    |> Enum.filter(& &1.encrypted)
    |> Enum.reduce_while({:ok, []}, fn definition, {:ok, acc} ->
      case declared_value(definition, agent_uid) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp declared_value(%Definition{worker_env_name: name} = definition, agent_uid) do
    with :ok <- ensure_exportable(definition) do
      case AppConfigure.resolve(definition, agent_id: agent_uid) do
        {:ok, %Resolution{value: nil}} -> {:ok, nil}
        {:ok, %Resolution{value: value}} when is_binary(value) -> {:ok, value}
        # The offending value stays out of the error tuple: it may be a secret.
        {:ok, %Resolution{}} -> {:error, {:invalid_worker_env_value, name, definition.key}}
        :error -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A reserved declared name is a first-party declaration bug; failing the
  # resolve keeps it from silently shadowing sandbox bootstrap variables.
  defp ensure_exportable(%Definition{worker_env_name: name}) do
    if reserved_name?(name) do
      {:error, {:reserved_worker_env_name, name}}
    else
      :ok
    end
  end

  defp put_declared_global(definition, attrs) do
    case Map.fetch(attrs, "value") do
      {:ok, value} ->
        with {:ok, _value} <- AppConfigure.put_global_by_key(definition.key, value) do
          {:ok, declared_item(definition, nil)}
        end

      :error ->
        preserve_declared_global(definition)
    end
  end

  defp put_declared_for_agent(agent_uid, definition, attrs) do
    case Map.fetch(attrs, "value") do
      {:ok, value} ->
        with {:ok, _value} <-
               AppConfigure.put_for_agent_by_key(agent_uid, definition.key, value) do
          {:ok, declared_item(definition, agent_uid)}
        end

      :error ->
        preserve_declared_for_agent(definition, agent_uid)
    end
  end

  defp preserve_declared_global(%Definition{encrypted: true} = definition) do
    case declared_item(definition, nil) do
      %{present: true} = item -> {:ok, item}
      _item -> {:error, :invalid_worker_env_value}
    end
  end

  defp preserve_declared_global(%Definition{}), do: {:error, :invalid_worker_env_value}

  defp preserve_declared_for_agent(%Definition{encrypted: true} = definition, agent_uid) do
    case declared_item(definition, agent_uid) do
      %{present: true, source: "agent"} = item -> {:ok, item}
      _item -> {:error, :invalid_worker_env_value}
    end
  end

  defp preserve_declared_for_agent(%Definition{}, _agent_uid),
    do: {:error, :invalid_worker_env_value}

  defp decrypt_declared(%Definition{encrypted: false}, _agent_uid), do: {:error, :not_encrypted}

  defp decrypt_declared(%Definition{} = definition, agent_uid) do
    opts = if agent_uid, do: [agent_id: agent_uid], else: []

    case AppConfigure.get(definition, opts) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp declared_item(%Definition{} = definition, agent_uid, opts \\ []) do
    resolve_opts = if agent_uid, do: [agent_id: agent_uid], else: []

    base = %{
      name: definition.worker_env_name,
      kind: "declared",
      secret: definition.encrypted,
      description: definition.description,
      declared_key: definition.key,
      editable: true
    }

    result =
      case Keyword.fetch(opts, :repo) do
        {:ok, repo} -> AppConfigure.resolve_in_tx(repo, definition, resolve_opts)
        :error -> AppConfigure.resolve(definition, resolve_opts)
      end

    case result do
      {:ok, %Resolution{value: nil, source: source}} ->
        Map.merge(base, %{present: false, source: Atom.to_string(source)})

      {:ok, %Resolution{value: value, source: source}} ->
        base
        |> Map.merge(%{present: true, source: Atom.to_string(source)})
        |> put_plain_value(definition.encrypted, value)

      :error ->
        Map.merge(base, %{present: false, source: "missing"})

      {:error, reason} ->
        Map.merge(base, %{present: false, source: "error", error: inspect(reason)})
    end
  end

  # ---- custom track ----

  defp custom_env(scope) do
    scope
    |> custom_rows()
    |> Enum.reduce_while({:ok, %{}}, fn row, {:ok, acc} ->
      case row_value(row) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, row.name, value)}}

        {:error, reason} ->
          {:halt, {:error, {:worker_env_row_error, scope, row.name, reason}}}
      end
    end)
  end

  defp custom_sensitive_values(scope) do
    scope
    |> custom_rows()
    |> Enum.filter(& &1.secret)
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case row_value(row) do
        {:ok, value} ->
          {:cont, {:ok, [value | acc]}}

        {:error, reason} ->
          {:halt, {:error, {:worker_env_row_error, scope, row.name, reason}}}
      end
    end)
  end

  defp custom_rows(scope) do
    EnvVar
    |> where([row], row.scope == ^scope)
    |> Repo.all()
  end

  defp rows_by_name(scope), do: scope |> custom_rows() |> Map.new(&{&1.name, &1})

  defp custom_row(scope, name) do
    EnvVar
    |> where([row], row.scope == ^scope and row.name == ^name)
    |> Repo.one()
  end

  defp row_value(%EnvVar{secret: false, value: value}), do: {:ok, value}

  defp row_value(%EnvVar{secret: true} = row),
    do: Crypto.unseal(row.value, row.scope, row.name)

  defp upsert_custom(scope, name, attrs, existing) do
    with {:ok, secret} <- custom_secret(attrs, existing),
         {:ok, description} <- custom_description(attrs, existing),
         {:ok, stored_value} <- custom_stored_value(attrs, existing, secret, scope, name),
         {:ok, row} <- upsert_row(scope, name, secret, stored_value, description) do
      {:ok, custom_item(row, custom_source(row))}
    end
  end

  defp custom_stored_value(attrs, existing, secret, scope, name) do
    case Map.fetch(attrs, "value") do
      {:ok, value} when is_binary(value) -> stored_value(value, secret, scope, name)
      {:ok, _value} -> {:error, :invalid_worker_env_value}
      :error -> preserve_custom_stored_value(existing, secret, scope, name)
    end
  end

  defp preserve_custom_stored_value(nil, _secret, _scope, _name),
    do: {:error, :invalid_worker_env_value}

  defp preserve_custom_stored_value(%EnvVar{secret: secret, value: value}, secret, _scope, _name),
    do: {:ok, value}

  defp preserve_custom_stored_value(%EnvVar{} = existing, secret, scope, name) do
    with {:ok, value} <- row_value(existing) do
      stored_value(value, secret, scope, name)
    end
  end

  # Flipping secret on an existing row re-seals or re-exposes on this write;
  # an absent flag keeps the stored state instead of silently decrypting.
  defp custom_secret(attrs, existing) do
    case Map.fetch(attrs, "secret") do
      {:ok, secret} when is_boolean(secret) -> {:ok, secret}
      {:ok, _secret} -> {:error, :invalid_worker_env_secret}
      :error -> {:ok, if(existing, do: existing.secret, else: false)}
    end
  end

  defp custom_description(attrs, existing) do
    case Map.fetch(attrs, "description") do
      {:ok, nil} -> {:ok, nil}
      {:ok, description} when is_binary(description) -> {:ok, description}
      {:ok, _description} -> {:error, :invalid_worker_env_description}
      :error -> {:ok, if(existing, do: existing.description, else: nil)}
    end
  end

  defp stored_value(value, false, _scope, _name), do: {:ok, value}
  defp stored_value(value, true, scope, name), do: Crypto.seal(value, scope, name)

  defp upsert_row(scope, name, secret, stored_value, description) do
    now = DateTime.utc_now(:second)

    changeset =
      EnvVar.changeset(%EnvVar{}, %{
        scope: scope,
        name: name,
        secret: secret,
        value: stored_value,
        description: description,
        inserted_at: now,
        updated_at: now
      })

    case Repo.insert(changeset,
           on_conflict: [
             set: [secret: secret, value: stored_value, description: description, updated_at: now]
           ],
           conflict_target: [:scope, :name],
           returning: true
         ) do
      {:ok, row} -> {:ok, row}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp delete_row(%EnvVar{} = row) do
    EnvVar
    |> where([r], r.scope == ^row.scope and r.name == ^row.name)
    |> Repo.delete_all()

    :ok
  end

  defp decrypt_row(%EnvVar{secret: false}), do: {:error, :not_encrypted}
  defp decrypt_row(%EnvVar{} = row), do: row_value(row)

  defp custom_item(%EnvVar{} = row, source) do
    %{
      name: row.name,
      kind: "custom",
      secret: row.secret,
      description: row.description,
      present: true,
      source: source,
      editable: true
    }
    |> put_plain_value(row.secret, row.value)
  end

  defp custom_source(%EnvVar{scope: @global_scope}), do: "global"
  defp custom_source(%EnvVar{}), do: "agent"

  defp put_plain_value(item, true, _value), do: item
  defp put_plain_value(item, false, value), do: Map.put(item, :value, value)

  # ---- routing ----

  # A name resolves to its custom row first because merge precedence puts
  # custom rows above declared values; editing must target what the shell
  # actually sees. `route/2` looks at one scope tier (used by writes), while
  # `route_for_agent/2` follows the agent's effective fallback chain.
  defp route(scope, name) do
    case custom_row(scope, name) do
      %EnvVar{} = row -> {:custom, row}
      nil -> route_declared(name)
    end
  end

  defp route_for_agent(scope, name) do
    case custom_row(scope, name) do
      %EnvVar{} = row -> {:custom, row}
      nil -> route(@global_scope, name)
    end
  end

  defp route_declared(name) do
    case Enum.find(declared_definitions(), &(&1.worker_env_name == name)) do
      %Definition{} = definition -> {:declared, definition}
      nil -> :unknown
    end
  end

  defp deleted_detail_global(name) do
    case route(@global_scope, name) do
      :unknown -> {:ok, deleted_item(name)}
      _still_present -> console_detail_global(name)
    end
  end

  defp deleted_detail_for_agent(agent_uid, name) do
    with {:ok, scope} <- agent_scope(agent_uid) do
      case route_for_agent(scope, name) do
        :unknown -> {:ok, deleted_item(name)}
        _still_present -> console_detail_for_agent(agent_uid, name)
      end
    end
  end

  defp deleted_item(name) do
    %{
      name: name,
      kind: "custom",
      secret: false,
      description: nil,
      present: false,
      source: "missing",
      editable: true
    }
  end

  # ---- scope helpers ----

  defp agent_scope(agent_uid) when is_binary(agent_uid) and agent_uid != "" do
    {:ok, @agent_scope_prefix <> agent_uid}
  end

  defp agent_scope(_agent_uid), do: {:error, :invalid_agent_id}

  defp ensure_agent(agent_uid) do
    case Principals.get_agent(agent_uid) do
      {:ok, _agent} -> :ok
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
