defmodule Ankole.SignalsGateway.ProjectionTest do
  use Ankole.DataCase, async: false

  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.IngressFact
  alias Ankole.SignalsGateway.Projection

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @channel_id "lark:chat:busy-group"

  test "principal destinations resolve only one observed DM in the Agent binding" do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    %{principal: other} = Ankole.PrincipalsFixtures.agent_fixture()
    %{principal: peer} = Ankole.PrincipalsFixtures.human_fixture()
    binding = Ankole.SignalsGatewayFixtures.binding_fixture(agent.uid, "dm", :ignore)
    other_binding = Ankole.SignalsGatewayFixtures.binding_fixture(other.uid, "dm", :ignore)

    for adapter <- [Ankole.Plugins.LarkAdapter.Outbox, Ankole.Plugins.SlackAdapter.Outbox] do
      assert {:error, :principal_conversation_not_observed} =
               adapter.open_conversation(binding, peer.uid)
    end

    foreign = observed_dm(other_binding, peer, "foreign")
    assert {:ok, ^foreign} = Projection.existing_direct_conversation(other_binding, peer.uid)

    assert {:error, :principal_conversation_not_observed} =
             Projection.existing_direct_conversation(binding, peer.uid)

    own = observed_dm(binding, peer, "own")

    for adapter <- [Ankole.Plugins.LarkAdapter.Outbox, Ankole.Plugins.SlackAdapter.Outbox] do
      assert {:ok, ^own} = adapter.open_conversation(binding, peer.uid)
      assert {:ok, ^own} = adapter.open_conversation(binding, peer.uid)
    end

    assert Repo.get_by!(Channel, id: own.id) == own

    _second = observed_dm(binding, peer, "second")

    assert {:error, :principal_conversation_ambiguous} =
             Projection.existing_direct_conversation(binding, peer.uid)
  end

  defp observed_dm(binding, peer, suffix) do
    channel_id = "lark:dm:#{binding.agent_uid}:#{suffix}"

    {:ok, %{actor_event: event}} =
      Repo.transact(fn _repo ->
        {:ok,
         Ankole.SignalsGatewayFixtures.emit_addressed_actor_event(
           binding.agent_uid,
           binding.name,
           Ankole.SignalsGatewayFixtures.group_entry(%{
             signal_channel_id: channel_id,
             source_event_id: channel_id,
             channel: %{kind: :im_dm, reply_mode: :channel},
             author: %{principal_uid: peer.uid, display_name: peer.display_name}
           })
         )}
      end)

    assert event.signal_channel_id == channel_id
    Repo.get_by!(Channel, id: channel_id)
  end

  describe "link_payload_attachments/3" do
    test "names every stored attachment that a payload shows in the Agent's drive" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      entry_file = stored_attachment("report.pdf", "report")
      quoted_file = stored_attachment("chart.png", "chart")
      batch_file = stored_attachment("notes.txt", "notes")
      unreplied_file = stored_attachment("pending.txt", "pending")

      payload = %{
        "data" => %{
          "entry" => %{
            "attachments" => [entry_file, %{"name" => "pending.pdf"}],
            "reply_to" => %{"attachments" => [quoted_file]}
          },
          "entries" => [%{"attachments" => [batch_file, entry_file]}],
          "unreplied_messages" => [%{"attachments" => [unreplied_file]}]
        }
      }

      for channel_id <- ["lark:chat:first", "lark:chat:second"] do
        assert :ok = Projection.link_payload_attachments(agent.uid, payload, channel_id)

        for file <- [entry_file, quoted_file, batch_file, unreplied_file] do
          path = Ankole.Files.chat_path(channel_id, file["path"])

          assert {:ok, %{source: "inbound", signal_channel_id: ^channel_id}} =
                   Ankole.Files.fetch(agent.uid, path)
        end

        assert {:ok, %{files: files}} =
                 Ankole.Files.list(agent.uid, Ankole.Files.chat_directory(channel_id) <> "/inbox")

        assert length(files) == 4
      end

      assert {:ok, %{files: []}} = Ankole.Files.list(agent.uid, "inbox")
    end

    test "keeps a drive file that its writer named, with its source and provenance" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
      {:ok, %{sha256: sha256}} = Ankole.Files.store("sent chart")
      path = Ankole.Files.content_path("sent", sha256, "chart.png")

      {:ok, _files} =
        Ankole.Files.commit(agent.uid, [
          %{
            path: path,
            sha256: sha256,
            source: "sent",
            signal_channel_id: "channel-1",
            source_entry_id: "message-1"
          }
        ])

      # A person quotes the message that carried the Agent's own attachment.
      quoted = %{"name" => "chart.png", "blob_ref" => sha256, "path" => path}
      payload = %{"data" => %{"entry" => %{"reply_to" => %{"attachments" => [quoted]}}}}

      assert :ok = Projection.link_payload_attachments(agent.uid, payload, "channel-1")

      assert {:ok,
              %{source: "sent", signal_channel_id: "channel-1", source_entry_id: "message-1"}} =
               Ankole.Files.fetch(agent.uid, path)
    end
  end

  describe "update_channel_metadata/2" do
    test "a max-style update keeps the newer value when an older write follows" do
      mirror_entry!("seed", "provider-alice", @base_time, [])
      newer = DateTime.add(@base_time, 3_600, :second)
      older = DateTime.add(@base_time, -3_600, :second)

      assert {:ok, _channel} =
               Projection.update_channel_metadata(@channel_id, &keep_newest(&1, newer))

      assert {:ok, _channel} =
               Projection.update_channel_metadata(@channel_id, &keep_newest(&1, older))

      assert %Channel{metadata: %{"seen_at" => stored}} = Repo.get_by(Channel, id: @channel_id)
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

      assert %Channel{metadata: metadata} = Repo.get_by(Channel, id: @channel_id)
      assert metadata["adapter_fact"] == "one"
      assert metadata["other_fact"] == "two"
    end

    test "an unknown channel is reported instead of created" do
      assert {:error, :signal_channel_not_found} =
               Projection.update_channel_metadata("lark:chat:missing", & &1)

      assert is_nil(Repo.get_by(Channel, id: "lark:chat:missing"))
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

  defp stored_attachment(name, content) do
    {:ok, attachment} = Ankole.SignalsGateway.Ingress.store_attachment(%{"name" => name}, content)
    attachment
  end
end
