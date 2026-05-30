defmodule BullX.Repo.Migrations.BackfillFeishuUserIdExternalIdentities do
  use Ecto.Migration

  alias BullX.Principals.ExternalIdentity

  def up do
    now = DateTime.utc_now(:microsecond)

    rows =
      repo()
      |> fetch_feishu_identity_rows()
      |> Enum.map(&canonical_identity_row(&1, now))
      |> Enum.reject(&is_nil/1)

    repo().insert_all(ExternalIdentity, rows, on_conflict: :nothing)
  end

  def down, do: :ok

  defp fetch_feishu_identity_rows(repo) do
    repo.query!("""
    SELECT kind::text, principal_uid, provider, adapter, channel_id, verified_at, metadata
    FROM principal_external_identities
    WHERE kind = 'channel_actor'
      AND adapter = 'feishu'
      AND external_id NOT LIKE 'feishu:user_id:%'
      AND COALESCE(metadata->'profile'->>'uid', metadata->'profile'->>'user_id') IS NOT NULL

    UNION ALL

    SELECT kind::text, principal_uid, provider, adapter, channel_id, verified_at, metadata
    FROM principal_external_identities
    WHERE kind = 'login_subject'
      AND metadata->'metadata'->>'adapter' = 'feishu'
      AND external_id NOT LIKE 'feishu:user_id:%'
      AND COALESCE(metadata->'profile'->>'uid', metadata->'profile'->>'user_id') IS NOT NULL
    """).rows
  end

  defp canonical_identity_row(
         [kind, principal_uid, provider, adapter, channel_id, verified_at, metadata],
         now
       ) do
    case feishu_user_id(metadata) do
      nil ->
        nil

      user_id ->
        %{
          id: BullX.Ext.gen_uuid_v7(),
          principal_uid: principal_uid,
          kind: String.to_existing_atom(kind),
          provider: provider,
          adapter: adapter,
          channel_id: channel_id,
          external_id: "feishu:user_id:" <> user_id,
          verified_at: verified_at,
          metadata: metadata,
          inserted_at: now,
          updated_at: now
        }
    end
  end

  defp feishu_user_id(%{"profile" => %{} = profile}) do
    first_string([profile["uid"], profile["user_id"]])
  end

  defp feishu_user_id(_metadata), do: nil

  defp first_string(values) do
    Enum.find_value(values, fn
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end)
  end
end
