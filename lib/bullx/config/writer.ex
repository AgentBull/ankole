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

  @doc "Deletes a key from `app_configs` and refreshes ETS."
  def delete(key) when is_binary(key) do
    BullX.Repo.delete_all(from c in BullX.Config.AppConfig, where: c.key == ^key)
    BullX.Config.Cache.refresh(key)
    BullX.Config.ReqLLM.Bridge.sync_if_req_llm_key(key)
  end

  defp do_put(key, stored_value, type) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    result =
      BullX.Repo.insert(
        %BullX.Config.AppConfig{key: key, value: stored_value, type: type},
        on_conflict: [set: [value: stored_value, type: type, updated_at: now]],
        conflict_target: :key
      )

    case result do
      {:ok, _} ->
        BullX.Config.Cache.refresh(key)
        BullX.Config.ReqLLM.Bridge.sync_if_req_llm_key(key)

      {:error, changeset} ->
        {:error, changeset}
    end
  end
end
