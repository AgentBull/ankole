defmodule BullX.EventBus.PersistenceTest do
  use BullX.DataCase, async: false

  alias BullX.EventBus.{Cleanup, TargetSession, TargetSessionEntry}

  test "cleanup deletes retained terminal sessions and entries" do
    session = insert_session!(%{status: :closed})
    entry = insert_entry!(session)
    old_updated_at = DateTime.add(DateTime.utc_now(:microsecond), -120, :second)

    Repo.update_all(
      from(s in TargetSession, where: s.id == ^session.id),
      set: [updated_at: old_updated_at]
    )

    assert :ok = Cleanup.run(DateTime.utc_now(:microsecond))
    refute Repo.get(TargetSession, session.id)
    refute Repo.get(TargetSessionEntry, entry.id)
  end

  defp insert_session!(attrs) do
    defaults = %{
      event_routing_rule_id: BullX.Ext.gen_uuid_v7(),
      target_type: :ai_agent,
      target_ref: BullX.Ext.gen_uuid_v7(),
      scope_key: Jason.encode!(["scope"]),
      status: :active
    }

    %TargetSession{}
    |> TargetSession.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp insert_entry!(%TargetSession{} = session) do
    now = DateTime.utc_now(:microsecond)

    %TargetSessionEntry{}
    |> TargetSessionEntry.changeset(%{
      target_session_id: session.id,
      event_source: "test://source",
      event_id: BullX.Ext.gen_uuid_v7(),
      dedupe_hash: BullX.Ext.gen_uuid_v7(),
      cloud_event: %{"id" => "event"},
      routing_context: %{},
      appended_at: now
    })
    |> Repo.insert!()
  end
end
