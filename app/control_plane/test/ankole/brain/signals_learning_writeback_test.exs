defmodule Ankole.Brain.SignalsLearningWritebackTest do
  # The second write path: nobody called `remember`, and the conversation
  # still has to leave durable memory behind. This runs the real slice
  # extraction against a faked provider upstream, so what is asserted is
  # what the channel actually stores — holder, audience, and parent.
  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.AppConfigure
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.SignalsLearning
  alias Ankole.Repo

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)

    {:ok, _result} = SchemaPacks.install_packs([])

    %{principal: owner} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})
    %{principal: alice} = human_fixture()

    test_pid = self()

    base_url =
      start_upstream_server(fn %{path: "chat/completions", body: body} ->
        send(
          test_pid,
          {:extraction_prompt, body["messages"] |> List.first() |> Map.get("content")}
        )

        items = %{
          "items" => [
            %{
              "type" => "fact",
              "claim" => "Alice wants a written summary before any call",
              "kind" => "preference",
              "holder" => "people/" <> alice.uid,
              "scope" => "principal:" <> alice.uid,
              "notability" => "high",
              "confidence" => 0.75,
              "provenance" => "send me something written first"
            }
          ]
        }

        {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(items))}
      end)

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "brain-extract",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    {:ok, _value} =
      AppConfigure.put_global_by_key("brain.extraction_model", %{
        "provider_id" => "brain-extract",
        "model" => "fake-extract"
      })

    channel = insert_channel!()
    insert_entry!(channel.id, "m1", "send me something written first", alice.uid)
    insert_actor_event!(agent.uid, channel.id)

    %{agent: agent, alice: alice, channel: channel}
  end

  test "a private chat leaves the preference behind with its holder and audience",
       %{alice: alice, channel: channel} do
    assert {:ok, %{status: :complete, written: %{claims: 1}}} =
             SignalsLearning.process_channel(channel.id)

    assert_receive {:extraction_prompt, prompt}
    assert prompt =~ "send me something written first"

    assert [claim] =
             Claim
             |> where([claim], claim.signal_gateway_channel_id == ^channel.id)
             |> where([claim], claim.kind == "preference")
             |> Repo.all()

    assert claim.holder == "people/" <> alice.uid
    assert claim.audience_scope == "principal:" <> alice.uid
    # The entity never resolved, so the claim parents on the channel; the
    # participant's context-pack card is what carries it back.
    assert claim.object_slug == nil
  end

  defp insert_channel! do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Ankole.SignalsGateway.Channel.changeset(%Ankole.SignalsGateway.Channel{}, %{
        id: "test:writeback-#{System.unique_integer([:positive])}",
        kind: :im_dm,
        reply_mode: :entry,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: now,
        last_seen_at: now
      })
    )
  end

  defp insert_entry!(channel_id, source_entry_id, text, author_uid) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Ankole.SignalsGateway.Entry.changeset(%Ankole.SignalsGateway.Entry{}, %{
        document_id: "#{channel_id}:#{source_entry_id}",
        signal_channel_id: channel_id,
        source_entry_id: source_entry_id,
        text: text,
        author: %{"principal_uid" => author_uid, "display_name" => "Alice"},
        content_hash: Ankole.Kernel.xxh3_128_hex(text),
        first_seen_at: now,
        last_seen_at: now
      })
    )
  end

  defp insert_actor_event!(agent_uid, channel_id) do
    Repo.insert!(%Ankole.SignalsGateway.ActorEvent{
      agent_uid: agent_uid,
      binding_name: "test-binding",
      session_id: "signal-channel:" <> channel_id,
      source_event_id: "event-#{System.unique_integer([:positive])}",
      signal_channel_id: channel_id,
      type: "signal",
      available_at: DateTime.utc_now(:microsecond),
      queue_sequence: System.unique_integer([:positive]),
      payload: %{}
    })
  end
end
