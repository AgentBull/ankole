defmodule Ankole.AgentWorkers.WorkerEnv do
  @moduledoc """
  Operator-managed environment variables for Agent Computer shells.

  Rows resolve from site, tenant, then Agent. Binding credentials override
  operator rows, and a command's explicit environment has final precedence.
  Secret values are decrypted only for execution or an authorized reveal.
  """

  require Ash.Query

  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.AgentWorkers.WorkerEnv.EnvVar
  alias Ankole.AgentWorkers.WorkerEnv.SiteEnvVar
  alias Ankole.AgentWorkers.BindingWorkerEnv

  @global_scope "global"
  @agent_scope_prefix "agent:"

  @doc "Moves operator variables to the renamed Agent and re-seals secret values."
  def rename_agent_in_tx(old_uid, new_uid) do
    unless Repo.in_transaction?(),
      do:
        raise(Ankole.Errors.Framework.TransactionRequired,
          operation: {__MODULE__, :rename_agent_in_tx}
        )

    custom_rows(@agent_scope_prefix <> old_uid)
    |> Enum.reduce_while(:ok, fn row, :ok ->
      with {:ok, value} <- row_value(row),
           {:ok, _new} <-
             Ankole.Ash.create(EnvVar, :put, %{
               scope: @agent_scope_prefix <> new_uid,
               name: row.name,
               input: %{
                 "value" => value,
                 "secret" => row.secret,
                 "description" => row.description
               }
             }),
           :ok <- delete_row(row) do
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  @name_format ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

  # Variables the sandbox bootstrap or worker identity owns. Overriding them
  # from operator rows would not restrict the model (it can re-export inside
  # the shell); it would only break the sandbox contract in confusing ways.
  @reserved_names ~w(PATH HOME SHELL TERM LANG BASH_ENV ENV WORKER_ID DATABASE_URL CODEX_UNSAFE_ALLOW_NO_SANDBOX)
  @reserved_prefix "ANKOLE_"

  def effective_env_parts(agent_uid, opts \\ []) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid),
         {:ok, global} <- custom_env(@global_scope),
         {:ok, tenant} <- custom_env(tenant_scope()),
         {:ok, agent} <- custom_env(scope),
         {:ok, binding} <- BindingWorkerEnv.resolve(agent_uid, opts) do
      {:ok, %{operator: global |> Map.merge(tenant) |> Map.merge(agent), binding: binding}}
    end
  end

  @doc "Builds the non-secret WorkerEnv part of a BackgroundAgentJob runtime projection."
  def runtime_projection(agent_uid) do
    with {:ok, items} <- console_list_for_agent(agent_uid) do
      present = Enum.filter(items, & &1.present)

      {:ok,
       %{
         "names" => present |> Enum.map(& &1.name) |> Enum.sort(),
         "plain_values" => present |> Enum.reject(& &1.secret) |> Map.new(&{&1.name, &1.value})
       }}
    end
  end

  def console_list_global, do: {:ok, list_rows(rows_by_name(@global_scope))}

  def console_list_for_agent(agent_uid) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid) do
      rows =
        rows_by_name(@global_scope)
        |> Map.merge(rows_by_name(tenant_scope()))
        |> Map.merge(rows_by_name(scope))

      {:ok, list_rows(rows)}
    end
  end

  def console_put_global(name, attrs) when is_map(attrs) do
    with :ok <- validate_name(name),
         do: upsert_custom(@global_scope, name, attrs)
  end

  def console_put_for_agent(agent_uid, name, attrs) when is_map(attrs) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid),
         :ok <- validate_name(name),
         do: upsert_custom(scope, name, attrs)
  end

  def console_delete_global(name) do
    with :ok <- validate_name(name),
         %{scope: _} = row <- custom_row(@global_scope, name),
         :ok <- delete_row(row) do
      {:ok, deleted_item(name)}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def console_delete_for_agent(agent_uid, name) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid),
         :ok <- validate_name(name),
         %{scope: _} = row <- custom_row(scope, name),
         :ok <- delete_row(row) do
      deleted_detail(effective_row(scope, name), name)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def console_decrypt_global(name) do
    with :ok <- validate_name(name), do: decrypt(custom_row(@global_scope, name))
  end

  def console_decrypt_for_agent(agent_uid, name) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid),
         :ok <- validate_name(name),
         do: decrypt(effective_row(scope, name))
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

  # Returns whether a name belongs to the sandbox bootstrap or worker identity.
  #
  @spec reserved_name?(String.t()) :: boolean()
  defp reserved_name?(name) when is_binary(name) do
    name in @reserved_names or String.starts_with?(name, @reserved_prefix)
  end

  @doc "Returns exact operator-configured secret values for one Agent."
  def sensitive_values(agent_uid) do
    with {:ok, scope} <- agent_scope(agent_uid),
         :ok <- ensure_agent(agent_uid),
         {:ok, global} <- custom_sensitive_values(@global_scope),
         {:ok, tenant} <- custom_sensitive_values(tenant_scope()),
         {:ok, agent} <- custom_sensitive_values(scope) do
      {:ok, (global ++ tenant ++ agent) |> Enum.reject(&(&1 == "")) |> Enum.uniq()}
    end
  end

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

  defp schema_for_scope(@global_scope), do: SiteEnvVar
  defp schema_for_scope(_scope), do: EnvVar

  defp custom_rows(scope) do
    schema_for_scope(scope)
    |> Ash.Query.filter(scope == ^scope)
    |> Ankole.Ash.read!()
  end

  defp rows_by_name(scope), do: scope |> custom_rows() |> Map.new(&{&1.name, &1})

  defp custom_row(scope, name) do
    schema_for_scope(scope)
    |> Ash.Query.filter(scope == ^scope and name == ^name)
    |> Ankole.Ash.read_one!()
  end

  @doc false
  def row_value(%{secret: false, value: value}), do: {:ok, value}

  def row_value(%{secret: true} = row),
    do: Ankole.SecretKeyBase.unseal(row.value, "worker_env", [row.scope, row.name])

  defp upsert_custom(scope, name, attrs) do
    with {:ok, row} <-
           Ankole.Ash.create(schema_for_scope(scope), :put, %{
             scope: scope,
             name: name,
             input: attrs
           }) do
      {:ok, custom_item(row, custom_source(row))}
    end
  end

  defp delete_row(row) do
    with {:ok, _row} <- Ankole.Ash.destroy(row, :remove), do: :ok
  end

  defp decrypt_row(%{secret: false}), do: {:error, :not_encrypted}
  defp decrypt_row(%{scope: _} = row), do: row_value(row)

  defp custom_item(%{scope: _} = row, source) do
    %{
      name: row.name,
      secret: row.secret,
      description: row.description,
      present: true,
      source: source
    }
    |> put_plain_value(row.secret, row.value)
  end

  defp custom_source(%{scope: @global_scope}), do: "global"
  defp custom_source(%{scope: "tenant:" <> _}), do: "tenant"
  defp custom_source(%{}), do: "agent"

  defp put_plain_value(item, true, _value), do: item
  defp put_plain_value(item, false, value), do: Map.put(item, :value, value)

  defp list_rows(rows),
    do:
      rows
      |> Map.values()
      |> Enum.map(&custom_item(&1, custom_source(&1)))
      |> Enum.sort_by(& &1.name)

  defp detail(row), do: {:ok, custom_item(row, custom_source(row))}
  defp decrypt(nil), do: {:error, :not_found}
  defp decrypt(row), do: decrypt_row(row)
  defp deleted_detail(nil, name), do: {:ok, deleted_item(name)}
  defp deleted_detail(row, _name), do: detail(row)

  @doc false
  def effective_row(@global_scope, name), do: custom_row(@global_scope, name)
  def effective_row(scope, name), do: custom_row(scope, name) || tenant_row(name)
  defp tenant_row(name), do: custom_row(tenant_scope(), name) || custom_row(@global_scope, name)

  defp deleted_item(name) do
    %{
      name: name,
      secret: false,
      description: nil,
      present: false,
      source: "missing"
    }
  end

  @doc false
  def delete_agent_rows_in_tx(uid) do
    EnvVar
    |> Ash.Query.filter(scope == ^("agent:" <> uid))
    |> Ankole.Ash.destroy_where(:remove)
    |> case do
      {:ok, _rows} -> :ok
      {:error, error} -> Repo.rollback(error)
    end
  end

  def console_list_tenant do
    {:ok, rows_by_name(@global_scope) |> Map.merge(rows_by_name(tenant_scope())) |> list_rows()}
  end

  def console_put_tenant(name, attrs) when is_map(attrs) do
    with :ok <- validate_name(name),
         do: upsert_custom(tenant_scope(), name, attrs)
  end

  def console_delete_tenant(name) do
    with :ok <- validate_name(name) do
      case custom_row(tenant_scope(), name) do
        nil -> deleted_detail(tenant_row(name), name)
        row -> with :ok <- delete_row(row), do: deleted_detail(tenant_row(name), name)
      end
    end
  end

  def console_decrypt_tenant(name) do
    with :ok <- validate_name(name), do: decrypt(tenant_row(name))
  end

  defp tenant_scope, do: "tenant:" <> Repo.tenant_id!()

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
