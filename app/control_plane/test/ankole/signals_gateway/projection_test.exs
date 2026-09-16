defmodule Ankole.SignalsGateway.ProjectionTest do
  use Ankole.DataCase, async: true

  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.IngressFact
  alias Ankole.SignalsGateway.Projection

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @channel_id "lark:chat:busy-group"

  describe "update_channel_metadata/2" do
    test "a max-style update keeps the newer value when an older write follows" do
      mirror_entry!("seed", "provider-alice", @base_time, [])
      newer = DateTime.add(@base_time, 3_600, :second)
      older = DateTime.add(@base_time, -3_600, :second)

      assert {:ok, _channel} =
               Projection.update_channel_metadata(@channel_id, &keep_newest(&1, newer))

      assert {:ok, _channel} =
               Projection.update_channel_metadata(@channel_id, &keep_newest(&1, older))

      assert %Channel{metadata: %{"seen_at" => stored}} = Repo.get(Channel, @channel_id)
      assert {:ok, ^newer, _offset} = DateTime.from_iso8601(stored)
    end

    test "keys the caller does not touch survive the update" do
      mirror_entry!("seed", "provider-alice", @base_time, [])

      assert {:ok, _channel} =
               Projection.update_channel_metadata(
                 @channel_id,
                 &Map.put(&1, "adapter_fact", "one")
               )

      assert {:ok, _channel} =
               Projection.update_channel_metadata(@channel_id, &Map.put(&1, "other_fact", "two"))

      assert %Channel{metadata: metadata} = Repo.get(Channel, @channel_id)
      assert metadata["adapter_fact"] == "one"
      assert metadata["other_fact"] == "two"
    end

    test "an unknown channel is reported instead of created" do
      assert {:error, :signal_channel_not_found} =
               Projection.update_channel_metadata("lark:chat:missing", & &1)

      assert is_nil(Repo.get(Channel, "lark:chat:missing"))
    end
  end

  describe "recent_entry_attachments/5" do
    test "author filter applies before the entry window in a busy channel" do
      mirror_entry!("alice-file", "provider-alice", @base_time, [
        %{"provider_ref" => "lark:file:alice-report", "name" => "report.pdf"}
      ])

      for index <- 1..25 do
        mirror_entry!(
          "bob-noise-#{index}",
          "provider-bob",
          DateTime.add(@base_time, index, :second),
          []
        )
      end

      query_time = DateTime.add(@base_time, 30, :second)

      assert [%{"provider_ref" => "lark:file:alice-report", "name" => "report.pdf"}] =
               Repo
               |> Projection.recent_entry_attachments(
                 @channel_id,
                 "provider-alice",
                 query_time
               )
               |> Enum.map(&Map.take(&1, ["provider_ref", "name"]))

      assert Projection.recent_entry_attachments(
               Repo,
               @channel_id,
               "provider-carol",
               query_time
             ) == []
    end
  end

  defp keep_newest(metadata, candidate) do
    stored =
      case metadata["seen_at"] do
        value when is_binary(value) ->
          case DateTime.from_iso8601(value) do
            {:ok, at, _offset} -> at
            _invalid -> nil
          end

        _missing ->
          nil
      end

    if is_nil(stored) or DateTime.compare(candidate, stored) == :gt,
      do: Map.put(metadata, "seen_at", DateTime.to_iso8601(candidate)),
      else: metadata
  end

  defp mirror_entry!(source_entry_id, author_id, provider_time, attachments) do
    assert {:ok, fact} =
             IngressFact.entry(%{
               agent_uid: "agent-projection-test",
               binding_name: "bot",
               adapter: "lark",
               source_event_id: "evt-" <> source_entry_id,
               signal_channel_id: @channel_id,
               source_entry_id: source_entry_id,
               channel_kind: :im_group,
               reply_mode: :entry,
               channel_name: "Busy",
               channel_visibility: nil,
               channel_metadata: %{},
               channel_raw_payload: %{},
               text: "message " <> source_entry_id,
               formatted_content: %{},
               attachments: attachments,
               links: [],
               author: %{"id" => author_id, "display_name" => author_id},
               mentions: [],
               metadata: %{},
               raw_payload: %{},
               provider_time: provider_time
             })

    assert {:ok, _entry} =
             Repo.transact(fn repo ->
               with {:ok, _channel} <- Projection.upsert_channel(repo, fact, provider_time) do
                 Projection.mirror_receive_entry(repo, fact, provider_time)
               end
             end)
  end
end
