defmodule Ankole.Tenants.DeletionHooks do
  @moduledoc """
  Extensible tenant deletion hooks and per-tenant fan-out execution for `Ankole.Tenants`.
  """

  alias Ankole.Repo

  @deletion_hooks_key :tenant_deletion_hooks

  @doc "Registers an idempotent tenant deletion hook (`{module, fun}`, `module`, or 1-arity fun)."
  def register_deletion_hook(hook) do
    hooks = deletion_hooks()

    if hook in hooks do
      :ok
    else
      Application.put_env(:ankole, @deletion_hooks_key, hooks ++ [hook])
      :ok
    end
  end

  @doc "Unregisters a previously registered tenant deletion hook."
  def unregister_deletion_hook(hook) do
    hooks = deletion_hooks()

    if hook in hooks do
      Application.put_env(:ankole, @deletion_hooks_key, Enum.reject(hooks, &(&1 == hook)))
    end

    :ok
  end

  @doc "Returns the configured tenant deletion hooks."
  def deletion_hooks do
    Application.get_env(:ankole, @deletion_hooks_key, [])
  end

  @doc "Executes all registered tenant deletion hooks as a retryable step."
  def run_deletion_hooks(tenant_id) when is_binary(tenant_id) do
    Enum.reduce_while(deletion_hooks(), :ok, fn hook, :ok ->
      case invoke_deletion_hook(hook, tenant_id) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:invalid_deletion_hook_return, hook, other}}}
      end
    end)
  end

  defp invoke_deletion_hook({mod, fun}, tenant_id) when is_atom(mod) and is_atom(fun) do
    _ = Code.ensure_loaded(mod)

    if function_exported?(mod, fun, 1) do
      apply(mod, fun, [tenant_id])
    else
      {:error, {:undefined_deletion_hook, {mod, fun}}}
    end
  end

  defp invoke_deletion_hook(mod, tenant_id) when is_atom(mod) do
    _ = Code.ensure_loaded(mod)

    cond do
      function_exported?(mod, :cleanup_tenant, 1) -> mod.cleanup_tenant(tenant_id)
      function_exported?(mod, :delete_tenant, 1) -> mod.delete_tenant(tenant_id)
      true -> {:error, {:undefined_deletion_hook, mod}}
    end
  end

  defp invoke_deletion_hook(fun, tenant_id) when is_function(fun, 1) do
    fun.(tenant_id)
  end

  @doc false
  def map_tenants(tenants, fun) when is_list(tenants) and is_function(fun, 0) do
    Enum.map(tenants, fn tenant ->
      result = Repo.with_tenant(tenant.id, fn -> run_fanout_item(tenant.id, fun) end)
      {tenant.id, result}
    end)
  end

  defp run_fanout_item(tenant_id, fun) do
    case fun.() do
      {:error, reason} = error ->
        log_fanout_failure(tenant_id, :error, reason, [])
        error

      result ->
        result
    end
  rescue
    error ->
      log_fanout_failure(tenant_id, :error, error, __STACKTRACE__)
      {:error, {:exception, Exception.message(error)}}
  catch
    kind, reason ->
      log_fanout_failure(tenant_id, kind, reason, __STACKTRACE__)
      {:error, {kind, reason}}
  end

  defp log_fanout_failure(tenant_id, kind, reason, stacktrace) do
    Ankole.Logging.warning(
      "tenants.site_fanout_failed",
      "Site work failed for one tenant",
      Ankole.Logging.failure_fields(kind, reason, stacktrace) |> Map.put(:tenant_id, tenant_id)
    )
  end

  @doc false
  def fanout_result(results) do
    errors = for {tenant_id, {:error, reason}} <- results, do: {tenant_id, reason}

    case errors do
      [] -> :ok
      errors -> {:error, {:tenant_failures, errors}}
    end
  end
end
