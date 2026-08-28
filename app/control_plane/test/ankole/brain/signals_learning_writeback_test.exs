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
              # The model tries to widen a private source. The server must
              # clamp this value to the source audience.
              "scope" => "world",
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
    assert prompt =~ "source audience is an upper bound"
    assert prompt =~ ~s("world" for content learned from this conversation)
    # No stored page matches this transcript, so the dedup block stays out.
    refute prompt =~ "Known pages already in memory"

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

  test "a group chat cannot promote learned memory to world", %{
    agent: agent,
    alice: alice
  } do
    {:ok, group} =
      Ankole.AuthZ.create_principal_group(%{
        name: "learning-team-#{System.unique_integer([:positive])}",
        display_name: "Learning Team",
        domain: :operator,
        kind: :static
      })

    channel = insert_channel!(%{kind: :im_group, principal_group_id: group.id})
    insert_entry!(channel.id, "g1", "send me something written first", alice.uid)
    insert_actor_event!(agent.uid, channel.id)

    assert {:ok, %{status: :complete, written: %{claims: 1}}} =
             SignalsLearning.process_channel(channel.id)

    assert [claim] =
             Claim
             |> where([claim], claim.signal_gateway_channel_id == ^channel.id)
             |> where([claim], claim.kind == "preference")
             |> Repo.all()

    assert claim.audience_scope == "group:#{group.name}"
  end

  describe "known page injection" do
    # The counterfactual behind write-time dedup: the model only reuses an
    # existing page when the prompt names it. The faked model plays an
    # obedient extractor — with the known-page list it files under the
    # listed slug, without the list it declares the same entity as a new
    # page — so a regression that drops the injection fails the
    # single-page assertion below.
    setup %{alice: alice} do
      {:ok, _object} =
        Ankole.Brain.Objects.create_object(
          %{slug: "companies/acme", type: "company", title: "Acme Corporation"},
          :system
        )

      {:ok, _alias} = Ankole.Brain.Links.add_alias("companies/acme", "acme")

      test_pid = self()
      holder = "people/" <> alice.uid

      base_url =
        start_upstream_server(fn %{path: "chat/completions", body: body} ->
          prompt = body["messages"] |> List.first() |> Map.get("content")
          send(test_pid, {:dedup_prompt, prompt})

          items =
            if prompt =~ "companies/acme — Acme Corporation" do
              [
                %{
                  "type" => "fact",
                  "claim" => "Acme wants to renew before the end of the quarter",
                  "kind" => "commitment",
                  "holder" => holder,
                  "notability" => "high",
                  "confidence" => 0.7,
                  "object_slug" => "companies/acme",
                  "provenance" => "renewal message"
                }
              ]
            else
              [
                %{
                  "type" => "object",
                  "slug" => "companies/acme-corp",
                  "object_type" => "company",
                  "title" => "Acme Corp",
                  "aliases" => ["acme"]
                },
                %{
                  "type" => "fact",
                  "claim" => "Acme wants to renew before the end of the quarter",
                  "kind" => "commitment",
                  "holder" => holder,
                  "notability" => "high",
                  "confidence" => 0.7,
                  "object_slug" => "companies/acme-corp",
                  "provenance" => "renewal message"
                }
              ]
            end

          body_text = Ankole.JSON.encode!(%{"items" => items})
          {:json, 200, chat_completion_body(body["model"], body_text)}
        end)

      {:ok, _provider} =
        ProviderConfigs.create_provider(%{
          provider_id: "brain-extract-dedup",
          provider_kind: "openrouter",
          base_url: base_url,
          credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
        })

      {:ok, _value} =
        AppConfigure.put_global_by_key("brain.extraction_model", %{
          "provider_id" => "brain-extract-dedup",
          "model" => "fake-extract"
        })

      :ok
    end

    test "a mentioned known entity reuses its page instead of creating a duplicate",
         %{agent: agent, alice: alice} do
      channel = insert_channel!()

      insert_entry!(
        channel.id,
        "d1",
        "Acme wants to renew before the end of the quarter",
        alice.uid
      )

      insert_actor_event!(agent.uid, channel.id)

      assert {:ok, %{status: :complete, written: %{claims: 1, objects: 0}}} =
               SignalsLearning.process_channel(channel.id)

      assert_receive {:dedup_prompt, prompt}
      assert prompt =~ "Known pages already in memory"
      assert prompt =~ "companies/acme — Acme Corporation (aka: acme)"
      assert prompt =~ "must reuse the listed slug"

      # One page, not two: the fact landed on the existing page and no
      # duplicate slug appeared.
      assert [%{slug: "companies/acme"}] =
               Ankole.Brain.Schemas.Object
               |> where([object], like(object.slug, "companies/%"))
               |> Repo.all()

      assert [claim] = Claim |> where([claim], claim.kind == "commitment") |> Repo.all()
      assert claim.object_slug == "companies/acme"
      assert claim.holder == "people/" <> alice.uid
    end
  end

  defp insert_channel!(overrides \\ %{}) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Ankole.SignalsGateway.Channel.changeset(
        %Ankole.SignalsGateway.Channel{},
        Map.merge(
          %{
            id: "test:writeback-#{System.unique_integer([:positive])}",
            kind: :im_dm,
            reply_mode: :entry,
            metadata: %{},
            raw_payload: %{},
            first_seen_at: now,
            last_seen_at: now
          },
          overrides
        )
      )
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
