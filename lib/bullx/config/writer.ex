defmodule BullX.Config.Writer do
  import Ecto.Query

  @doc "Upserts a string value into `app_configs` and refreshes ETS. Values for keys
  declared with `secret: true` are automatically encrypted before storage."
  def put(key, value) when is_binary(key) and is_binary(value) do
    if BullX.Config.SecretKeys.secret?(key) do
      with {:ok, ciphertext} <- BullX.Config.Crypto.encrypt(value, key) do
        do_put(key, ciphertext, :secret)
      end
    else
      do_put(key, value, :plain)
    end
  end

  @doc """
  Upserts multiple string values into `app_configs` in one PostgreSQL transaction.

  Secret values are encrypted before the transaction starts. A successful commit
  refreshes each changed key in ETS and runs the same subsystem post-write hooks
  as `put/2`; those refreshes are post-commit readiness work, not part of the
  database transaction.
  """
  def put_many(entries) when is_map(entries) do
    entries
    |> Map.to_list()
    |> put_many()
  end

  def put_many(entries) when is_list(entries) do
    with {:ok, prepared_entries} <- prepare_entries(entries) do
      do_put_many(prepared_entries)
    end
  end

  @doc "Deletes a key from `app_configs` and refreshes ETS."
  def delete(key) when is_binary(key) do
    BullX.Repo.delete_all(from c in BullX.Config.AppConfig, where: c.key == ^key)
    refresh_after_write([key])
  end

  defp do_put(key, stored_value, type) do
    prepared_entry = %{key: key, value: stored_value, type: type}
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case upsert_prepared(prepared_entry, now) do
      {:ok, _} ->
        refresh_after_write([key])

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp do_put_many([]), do: :ok

  defp do_put_many(prepared_entries) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case BullX.Repo.transaction(fn ->
           Enum.each(prepared_entries, &upsert_prepared!(&1, now))
         end) do
      {:ok, :ok} ->
        prepared_entries
        |> Enum.map(& &1.key)
        |> refresh_after_write()

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_entries(entries) do
    entries
    |> normalize_entries()
    |> case do
      {:ok, normalized_entries} -> encrypt_entries(normalized_entries)
      {:error, _reason} = error -> error
    end
  end

  defp normalize_entries(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_binary(key) and is_binary(value) ->
        {:cont, {:ok, Map.put(acc, key, value)}}

      _entry, _acc ->
        {:halt, {:error, :invalid_entries}}
    end)
  end

  defp encrypt_entries(entries) do
    Enum.reduce_while(entries, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case prepare_entry(key, value) do
        {:ok, prepared_entry} -> {:cont, {:ok, [prepared_entry | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp prepare_entry(key, value) do
    case BullX.Config.SecretKeys.secret?(key) do
      true ->
        with {:ok, ciphertext} <- BullX.Config.Crypto.encrypt(value, key) do
          {:ok, %{key: key, value: ciphertext, type: :secret}}
        end

      false ->
        {:ok, %{key: key, value: value, type: :plain}}
    end
  end

  defp upsert_prepared(prepared_entry, now) do
    BullX.Repo.insert(
      app_config(prepared_entry),
      on_conflict: [set: conflict_set(prepared_entry, now)],
      conflict_target: :key
    )
  end

  defp upsert_prepared!(prepared_entry, now) do
    BullX.Repo.insert!(
      app_config(prepared_entry),
      on_conflict: [set: conflict_set(prepared_entry, now)],
      conflict_target: :key
    )
  end

  defp app_config(%{key: key, value: value, type: type}) do
    %BullX.Config.AppConfig{key: key, value: value, type: type}
  end

  defp conflict_set(%{value: value, type: type}, now) do
    [value: value, type: type, updated_at: now]
  end

  defp refresh_after_write(keys) do
    keys
    |> Enum.flat_map(&refresh_key_after_write/1)
    |> projection_result()
  end

  defp refresh_key_after_write(key) do
    case BullX.Config.Cache.refresh(key) do
      :ok -> sync_req_llm_after_write(key)
      {:error, reason} -> [{:config_cache_refresh_failed, key, reason}]
    end
  end

  defp sync_req_llm_after_write(key) do
    case BullX.Config.ReqLLM.Bridge.sync_if_req_llm_key(key) do
      :ok -> []
      {:error, reason} -> [{:req_llm_projection_failed, key, reason}]
    end
  end

  defp projection_result([]), do: :ok
  defp projection_result([failure]), do: {:ok, {:persisted_but_stale, failure}}
  defp projection_result(failures), do: {:ok, {:persisted_but_stale, failures}}
end
