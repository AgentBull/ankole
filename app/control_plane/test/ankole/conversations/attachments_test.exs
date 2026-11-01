defmodule Ankole.Conversations.AttachmentsTest do
  use Ankole.DataCase, async: true

  alias Ankole.Repo
  alias Ankole.Conversations.Conversation
  import Ankole.ExternalConversationsFixtures
  alias Ankole.Conversations.{External, Attachments}

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @channel_id "lark:chat:busy-group"

  describe "attachment materialization" do
    test "stores download bytes with the adapter's name, type and added fields" do
      [stored] =
        Attachments.materialize_attachments(
          [%{"provider_ref" => "fixture:one", "name" => "source.txt"}],
          "fixture",
          fn _attachment ->
            {:ok,
             %{
               body: "download bytes",
               filename: "stored.txt",
               content_type: "text/plain",
               put: %{"mimetype" => "text/plain"}
             }}
          end
        )

      assert stored["name"] == "source.txt"
      assert Ecto.UUID.cast(stored["object_id"]) == {:ok, stored["object_id"]}
      refute Map.has_key?(stored, "path")
      assert stored["mimetype"] == "text/plain"
      assert stored["materialization_state"] == "complete"
      assert stored["size"] == byte_size("download bytes")
      assert Attachments.stored?(stored)
      refute Attachments.attachments_need_bytes?([stored])
      assert Attachments.materialization_state([stored]) == "complete"
    end

    test "does not fetch stored bytes or provider facts and drops credentials from every result" do
      {:ok, stored} = Attachments.store_attachment(%{"name" => "stored.bin"}, "stored")

      restricted = %{
        "provider_ref" => "fixture:large",
        "materialization_state" => "provider_download_limit",
        "restriction" => "original restriction"
      }

      external = %{
        "provider_ref" => "fixture:external",
        "materialization_state" => "provider_external_content"
      }

      attachments =
        Enum.map([stored, restricted, external], &Map.put(&1, "download_code", "temporary"))

      assert [^stored, ^restricted, ^external] =
               Attachments.materialize_attachments(
                 attachments,
                 "fixture",
                 fn _ -> flunk("must not download") end,
                 drop_keys: ["download_code"]
               )

      refute Attachments.attachments_need_bytes?(attachments)
      assert Attachments.materialization_state(attachments) == "complete"
    end

    test "records download limits without changing the provider restriction" do
      [attachment] =
        Attachments.materialize_attachments(
          [%{"provider_ref" => "fixture:large"}],
          "fixture",
          fn _ -> {:error, :provider_download_limit} end,
          restriction: "provider limit"
        )

      assert attachment["materialization_state"] == "provider_download_limit"
      assert attachment["restriction"] == "provider limit"
      assert Attachments.materialization_state([attachment]) == "complete"
    end

    test "failure and exception remove temporary keys and remain unsatisfied" do
      for download <- [fn _ -> {:error, :unavailable} end, fn _ -> raise "download failed" end] do
        [attachment] =
          Attachments.materialize_attachments(
            [
              %{
                "provider_ref" => "fixture:failed",
                "temp_url" => "temporary",
                "aeskey" => "secret"
              }
            ],
            "fixture",
            download,
            drop_keys: ["temp_url", "aeskey"]
          )

        assert attachment["materialization_state"] == "failed"
        refute Map.has_key?(attachment, "temp_url")
        refute Map.has_key?(attachment, "aeskey")
        assert Attachments.attachments_need_bytes?([attachment])
        assert Attachments.materialization_state([attachment]) == "failed"
      end
    end

    test "a failed observation can fetch again and become complete" do
      [attachment] =
        Attachments.materialize_attachments(
          [%{"provider_ref" => "fixture:retry", "materialization_state" => "failed"}],
          "fixture",
          fn _ ->
            {:ok, %{body: "retried", filename: "retry.bin", content_type: nil, put: %{}}}
          end
        )

      assert attachment["materialization_state"] == "complete"
      assert Attachments.stored?(attachment)
    end

    test "attachments need bytes until the file service holds every one of them" do
      stored = %{
        "attachment_id" => 10_042,
        "object_id" => Ecto.UUID.generate(),
        "path" => "inbox/abababababababab/report.pdf"
      }

      refute Attachments.attachments_need_bytes?([])
      refute Attachments.attachments_need_bytes?([stored])

      assert Attachments.attachments_need_bytes?([stored, %{"provider_ref" => "lark:file:fresh"}])
      assert Attachments.attachments_need_bytes?([%{"attachment_id" => 10_042}])
      refute Attachments.attachments_need_bytes?([Map.delete(stored, "path")])
      assert Attachments.attachments_need_bytes?([%{stored | "object_id" => ""}])
    end

    test "the observation metadata always carries the state and the observed time" do
      observed_at = DateTime.add(@base_time, 250, :millisecond)

      assert Attachments.put_attachment_materialization(
               %{"provider" => "discord"},
               "pending",
               observed_at
             ) == %{
               "provider" => "discord",
               "attachment_materialization" => %{
                 "state" => "pending",
                 "observed_at" => "2026-07-02T01:34:05.250000Z"
               }
             }

      assert_raise FunctionClauseError, fn ->
        Attachments.put_attachment_materialization(%{}, "downloading", observed_at)
      end
    end
  end

  test "principal destinations resolve only one observed DM in the Agent binding" do
    %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()
    %{principal: other} = Ankole.PrincipalsFixtures.agent_fixture()
    %{principal: peer} = Ankole.PrincipalsFixtures.human_fixture()
    binding = Ankole.SignalsFixtures.binding_fixture(agent.uid, "dm", :ignore)
    other_binding = Ankole.SignalsFixtures.binding_fixture(other.uid, "dm", :ignore)

    for adapter <- [Ankole.Plugins.LarkAdapter.Delivery, Ankole.Plugins.SlackAdapter.Delivery] do
      assert {:error, :principal_conversation_not_observed} =
               adapter.open_conversation(binding, peer.uid)
    end

    foreign = observed_dm(other_binding, peer, "foreign")
    assert {:ok, resolved} = External.existing_direct_conversation(other_binding, peer.uid)
    assert_persisted_equal(resolved, foreign)

    assert {:error, :principal_conversation_not_observed} =
             External.existing_direct_conversation(binding, peer.uid)

    own = observed_dm(binding, peer, "own")

    for adapter <- [Ankole.Plugins.LarkAdapter.Delivery, Ankole.Plugins.SlackAdapter.Delivery] do
      assert {:ok, resolved} = adapter.open_conversation(binding, peer.uid)
      assert_persisted_equal(resolved, own)
      assert {:ok, resolved} = adapter.open_conversation(binding, peer.uid)
      assert_persisted_equal(resolved, own)
    end

    Ankole.DataCase.assert_persisted_equal(Repo.get_by!(Conversation, id: own.id), own)

    _second = observed_dm(binding, peer, "second")

    assert {:error, :principal_conversation_ambiguous} =
             External.existing_direct_conversation(binding, peer.uid)
  end

  defp observed_dm(binding, peer, suffix) do
    channel_id = "lark:dm:#{binding.agent_uid}:#{suffix}"

    %{signal: event} =
      Ankole.SignalsFixtures.emit_addressed_signal(
        binding.agent_uid,
        binding.name,
        Ankole.SignalsFixtures.group_entry(%{
          provider_conversation_id: channel_id,
          source_event_id: channel_id,
          channel: %{kind: :im_dm, reply_mode: :channel},
          author:
            Ankole.SignalsFixtures.provider_author_fixture(peer.uid, peer.uid, %{
              display_name: peer.display_name
            })
        })
      )

    assert event.conversation_id == external_conversation_id(channel_id)
    Repo.get_by!(Conversation, id: event.conversation_id)
  end

  describe "prepare_payload_in_tx/2" do
    test "pins every stored attachment once in the shared conversation root" do
      message = mirror_entry!("seed", "provider-alice", @base_time, [])
      channel_id = message.conversation_id
      entry_file = stored_attachment("report.pdf", "report")
      quoted_file = stored_attachment("chart.png", "chart")

      payload = %{
        "data" => %{
          "entry" => %{
            "attachments" => [entry_file, %{"name" => "pending.pdf"}],
            "reply_to" => %{"attachments" => [quoted_file]}
          },
          "entries" => [%{"attachments" => [entry_file]}]
        }
      }

      assert {:ok, prepared} =
               Repo.transact(fn ->
                 {:ok, Attachments.prepare_payload_in_tx(payload, channel_id)}
               end)

      [file, pending] = prepared["data"]["entry"]["attachments"]
      assert file["node_id"]
      assert file == hd(hd(prepared["data"]["entries"])["attachments"])
      assert pending == %{"name" => "pending.pdf"}
      assert {:ok, "report"} = Ankole.Files.read_object(file["object_id"])

      assert {:ok, ^prepared} =
               Repo.transact(fn ->
                 {:ok, Attachments.prepare_payload_in_tx(payload, channel_id)}
               end)
    end

    test "preserves an existing quoted node and its frozen object identity" do
      %{principal: agent} = Ankole.PrincipalsFixtures.agent_fixture()

      file =
        Ankole.FilesFixtures.drive_file_fixture(agent.uid, "sent/chart.png", "sent chart", "sent")

      quoted = %{
        "name" => "chart.png",
        "object_id" => file.object_id,
        "node_id" => file.id,
        "path" => file.path
      }

      payload = %{"data" => %{"entry" => %{"reply_to" => %{"attachments" => [quoted]}}}}

      assert {:ok, ^payload} =
               Repo.transact(fn ->
                 {:ok,
                  Attachments.prepare_payload_in_tx(
                    payload,
                    external_conversation_id("test:channel-1")
                  )}
               end)
    end
  end

  describe "update_channel_metadata/2" do
    test "a max-style update keeps the newer value when an older write follows" do
      mirror_entry!("seed", "provider-alice", @base_time, [])
      newer = DateTime.add(@base_time, 3_600, :second)
      older = DateTime.add(@base_time, -3_600, :second)

      assert {:ok, _channel} =
               External.update_metadata(
                 external_conversation_id(@channel_id),
                 &keep_newest(&1, newer)
               )

      assert {:ok, _channel} =
               External.update_metadata(
                 external_conversation_id(@channel_id),
                 &keep_newest(&1, older)
               )

      assert %Conversation{metadata: %{"seen_at" => stored}} =
               Repo.get_by(Conversation, provider_conversation_id: @channel_id)

      assert {:ok, ^newer, _offset} = DateTime.from_iso8601(stored)
    end

    test "keys the caller does not touch survive the update" do
      mirror_entry!("seed", "provider-alice", @base_time, [])

      assert {:ok, _channel} =
               External.update_metadata(
                 external_conversation_id(@channel_id),
                 &Map.put(&1, "adapter_fact", "one")
               )

      assert {:ok, _channel} =
               External.update_metadata(
                 external_conversation_id(@channel_id),
                 &Map.put(&1, "other_fact", "two")
               )

      assert %Conversation{metadata: metadata} =
               Repo.get_by(Conversation, provider_conversation_id: @channel_id)

      assert metadata["adapter_fact"] == "one"
      assert metadata["other_fact"] == "two"
    end

    test "an unknown channel is reported instead of created" do
      assert {:error, :external_conversation_not_found} =
               External.update_metadata(Ecto.UUID.generate(), & &1)

      assert is_nil(Repo.get_by(Conversation, provider_conversation_id: "lark:chat:missing"))
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
               Attachments.recent(
                 external_conversation_id(@channel_id),
                 "provider-alice",
                 query_time,
                 []
               )
               |> Enum.map(&Map.take(&1, ["provider_ref", "name"]))

      assert Attachments.recent(
               external_conversation_id(@channel_id),
               "provider-carol",
               query_time,
               []
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

  defp mirror_entry!(provider_message_id, author_id, provider_time, attachments) do
    uid =
      Process.get(:attachment_test_agent) ||
        Ankole.PrincipalsFixtures.agent_fixture().principal.uid

    Process.put(:attachment_test_agent, uid)

    assert {:ok, %{message: entry}} =
             Repo.transact(fn ->
               with {:ok, conversation} <-
                      External.observe_conversation_in_tx(
                        %{agent_uid: uid},
                        %{
                          provider_conversation_id: @channel_id,
                          external_kind: :im_group,
                          reply_mode: :entry,
                          title: "Busy group"
                        },
                        provider_time
                      ) do
                 External.observe_in_tx(
                   conversation.id,
                   %{
                     provider_message_id: provider_message_id,
                     text: "message " <> provider_message_id,
                     author: %{"id" => author_id},
                     provider_time: provider_time,
                     attachments: attachments
                   },
                   provider_time
                 )
               end
             end)

    entry
  end

  defp stored_attachment(name, content) do
    {:ok, attachment} = Attachments.store_attachment(%{"name" => name}, content)
    attachment
  end
end
