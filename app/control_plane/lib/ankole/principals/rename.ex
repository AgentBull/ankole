defmodule Ankole.Principals.Rename do
  @moduledoc "The explicit tenant Principal rename and its post-commit Base repair."
  alias Ankole.{AgentWorkers, AppConfigure, Pod, Principals, Repo}
  alias Ankole.Principals.{Humans, Principal}
  alias Ankole.Principals.Rename.References

  def from_console(type, %{uid: uid, new_uid: new_uid}) do
    with {:ok, %{type: ^type}} <- Principals.get_principal(uid),
         {:ok, result} <- rename(uid, new_uid) do
      {:ok, %{uid: result.principal.uid, base_repair_error: result.base_repair_error}}
    else
      {:ok, _principal} -> {:error, :not_found}
      error -> error
    end
  end

  def rename(uid, new_uid) do
    with {:ok, new_uid} <- Principals.normalize_uid(new_uid),
         {:ok, principal} <- Principals.get_principal(uid),
         :ok <- validate_name(principal, new_uid),
         :ok <- prepare_worker(principal),
         {:ok, result} <- Repo.transact_top_level(fn -> rename_in_tx(principal.uid, new_uid) end) do
      publish(result)

      repair =
        Pod.repair_principal_references(result.principal.tenant_id, result.old_uid, new_uid)

      {:ok, %{principal: result.principal, base_repair_error: repair_error(repair)}}
    end
  end

  def rename_in_tx(uid, new_uid) do
    unless Repo.in_transaction?(),
      do:
        raise(Ankole.Errors.Framework.TransactionRequired, operation: {__MODULE__, :rename_in_tx})

    Ankole.Files.lock_tree_in_tx()

    with {:ok, uid} <- Principals.normalize_uid(uid),
         {:ok, new_uid} <- Principals.normalize_uid(new_uid),
         {:ok, principal} <- Humans.lock_principal_in_tx(uid),
         :ok <- validate_name(principal, new_uid),
         {:ok, worker} <- worker_for_rename(principal),
         {:ok, principal} <- Ankole.Ash.update(principal, :rename_in_tx, %{uid: new_uid}),
         :ok <- References.rewrite_in_tx(uid, new_uid, principal.type),
         :ok <- Ankole.Brain.rename_principal_references_in_tx(uid, new_uid, principal.type),
         {:ok, config_keys} <- rename_agent_scopes(worker, uid, new_uid),
         {:ok, bases} <- Pod.rename_inline_principal_in_tx(uid, new_uid),
         {:ok, pages} <- Pod.rename_principal_mentions_in_tx(uid, new_uid) do
      {:ok,
       %{principal: principal, old_uid: uid, config_keys: config_keys, pages: pages, bases: bases}}
    end
  end

  defp validate_name(%Principal{type: :system}, _new_uid), do: {:error, :system_uid_immutable}
  defp validate_name(%Principal{uid: uid}, uid), do: {:error, :principal_uid_unchanged}

  defp validate_name(%Principal{type: :agent}, uid) do
    if Ankole.Principals.Agent.valid_uid?(uid), do: :ok, else: {:error, :invalid_agent_uid}
  end

  defp validate_name(%Principal{type: :human}, uid) do
    if Regex.match?(~r/[\\\/:*?\[\]{}\s\p{C}]/u, uid),
      do: {:error, :invalid_uid},
      else: :ok
  end

  defp prepare_worker(%Principal{type: :agent, status: :disabled, uid: uid}) do
    case AgentWorkers.prepare_rename(uid) do
      {:ok, %{state: :absent}} -> :ok
      {:ok, _worker} -> {:error, :worker_rename_pending}
      {:error, _} = error -> error
    end
  end

  defp prepare_worker(%Principal{type: :agent}), do: {:error, :agent_must_be_disabled}
  defp prepare_worker(_principal), do: :ok

  defp worker_for_rename(%Principal{type: :agent, status: :disabled, uid: uid}) do
    case AgentWorkers.lock_in_tx(uid) do
      %{state: :absent} = worker -> {:ok, worker}
      _worker -> {:error, :worker_rename_pending}
    end
  end

  defp worker_for_rename(%Principal{type: :agent}), do: {:error, :agent_must_be_disabled}
  defp worker_for_rename(_principal), do: {:ok, nil}

  defp rename_agent_scopes(nil, _uid, _new_uid), do: {:ok, []}

  defp rename_agent_scopes(worker, uid, new_uid) do
    with {:ok, keys} <- AppConfigure.rename_agent_in_tx(uid, new_uid),
         :ok <- AgentWorkers.rename_env_in_tx(uid, new_uid),
         :ok <- AgentWorkers.rename_worker_in_tx(worker, new_uid),
         do: {:ok, keys}
  end

  def publish(result) do
    AppConfigure.publish_agent_rename(result.config_keys)
    Pod.publish_principal_rename(result.pages)
    Pod.publish_base_principal_rename(result.bases)
  end

  defp repair_error({:ok, _}), do: nil
  defp repair_error({:error, reason}), do: inspect(reason)
end
