defmodule Ankole.OIDCClientSourceIntegrationTest do
  use Ankole.AIGatewayCase

  import AnkoleWeb.AIGatewayControllerTestHelpers, only: [response_sse_events: 3]

  alias Ankole.AIGateway.OIDCClientConversations
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.AppConfigure
  alias Ankole.AuthZ
  alias Ankole.Brain.OIDCClientLearning
  alias Ankole.Brain.Recall
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.{Claim, Object, Source}
  alias Ankole.Brain.SourceLearning
  alias Ankole.Brain.Sources
  alias Ankole.OIDC
  alias AnkoleWeb.AIGatewayResponsesSocket

  setup do
    allow_cache_database_access()
    AppConfigure.Cache.clear_for_test()
    on_exit(fn -> AppConfigure.Cache.clear_for_test() end)
    {:ok, _} = SchemaPacks.install_packs([])

    test_pid = self()

    holder =
      start_supervised!(
        {Agent,
         fn ->
           %{
             output: %{"items" => [item("Cobalt customer requests delivery in October")]},
             response_text: "Suggested next step: confirm the date.",
             before_extract: nil
           }
         end}
      )

    base_url =
      start_upstream_server(fn
        %{path: "v1/responses"} ->
          {:sse, 200,
           response_sse_events(
             "resp_provider",
             "fake-chat",
             Agent.get(holder, & &1.response_text)
           )}

        %{path: "chat/completions", body: body} ->
          %{output: output, before_extract: before_extract} =
            Agent.get_and_update(holder, &{&1, %{&1 | before_extract: nil}})

          if before_extract, do: before_extract.()
          prompt = body["messages"] |> List.first() |> Map.fetch!("content")
          send(test_pid, {:extraction, prompt})
          {:json, 200, chat_completion_body(body["model"], Ankole.JSON.encode!(output))}
      end)

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "oidc-source-chat",
        provider_kind: "openai",
        base_url: "#{base_url}/v1",
        credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]}
      })

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: "oidc-source-extract",
        provider_kind: "openrouter",
        base_url: base_url,
        credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "sk-test"}]}
      })

    configure_brain_maintainer_profile!("light", "oidc-source-extract", "fake-extract")

    %{principal: human} = human_fixture()
    %{principal: outsider} = human_fixture()

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "oidc-source-#{System.unique_integer([:positive])}",
        display_name: "OIDC source readers",
        kind: "static"
      })

    {:ok, _} = AuthZ.add_principal_to_group(human.uid, group.id)
    client = client!(group.id)
    %{human: human, outsider: outsider, client: client, group: group, holder: holder}
  end

  test "stored OIDC requests become private, searchable Source evidence and survive Client deletion",
       ctx do
    run!(ctx, %{"input" => "stateless input", "store" => false})
    assert OIDCClientLearning.sweep() == 0

    first = run!(ctx, %{"input" => "Cobalt customer requests delivery in October."})
    assert {:ok, %{oidc_sources: 1}} = Ankole.Brain.SelfHealing.sweep()
    source = source!(ctx.client)
    assert source.default_audience_scope == nil
    assert_enqueued(worker: Ankole.Brain.Jobs.LearnSource, args: %{source_id: source.id})
    assert :ok = perform_job(Ankole.Brain.Jobs.LearnSource, %{source_id: source.id})
    assert_receive {:extraction, prompt}
    assert prompt =~ "resp_#{first.id}"
    assert prompt =~ ctx.human.uid
    assert prompt =~ "Generated assistant output"

    [object] = objects(source)
    assert object.meta["audience_scope"] == "principal:#{ctx.human.uid}"
    assert object.body =~ "resp_#{first.id}"
    assert {:ok, result} = Recall.recall(ctx.human.uid, %{query: "Cobalt October"})
    assert Enum.any?(result.claims, &(&1.object_slug == object.slug))
    assert Enum.any?(result.chunks, &(&1.object_slug == object.slug))

    assert {:ok, %{claims: [], chunks: []}} =
             Recall.recall(ctx.outsider.uid, %{query: "Cobalt October"})

    assert OIDCClientLearning.sweep() == 0
    assert {:ok, %{conversations: 0}} = SourceLearning.learn(source.id)
    refute_receive {:extraction, _prompt}, 50

    assert {:ok, _} = OIDC.delete_client(ctx.client.id)
    assert OIDCClientLearning.sweep() == 0
    assert Repo.get!(Message, first.id).metadata["oidc_client_id"] == ctx.client.id

    assert Enum.map(objects(source), &{&1.id, &1.body, &1.meta}) == [
             {object.id, object.body, object.meta}
           ]
  end

  test "another Client continuing the same Human conversation supplies only its own evidence",
       ctx do
    second_client = client!(ctx.group.id)
    first = run!(ctx, %{"input" => "First Client conversation"})

    run!(%{ctx | client: second_client}, %{
      "input" => "Second Client conversation",
      "previous_response_id" => "resp_#{first.id}"
    })

    assert OIDCClientLearning.sweep() == 2

    for client <- [ctx.client, second_client],
        do: assert({:ok, _} = SourceLearning.learn(source!(client).id))

    [first_object] = objects(source!(ctx.client))
    [second_object] = objects(source!(second_client))
    assert first_object.meta["conversation_id"] == second_object.meta["conversation_id"]
    assert first_object.body =~ "First Client conversation"
    refute first_object.body =~ "Second Client conversation"
    assert second_object.body =~ "Second Client conversation"
    refute second_object.body =~ "First Client conversation"
  end

  test "learning excludes Brain injection and instructions while retaining the submitted dialogue",
       ctx do
    {:ok, object} =
      Ankole.Brain.Objects.create_object(
        %{
          slug: "concepts/wire-format",
          type: "concept",
          title: "Wire Format",
          body: "Injected memory only"
        },
        :system
      )

    {:ok, _} = Ankole.Brain.Links.add_alias(object.slug, "Wire Format")

    {:ok, _} =
      Ankole.Brain.Claims.write_fact(
        %{
          object_slug: object.slug,
          claim: "Injected evidence must not be learned again",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "high",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "original source"
        },
        :system
      )

    message =
      run!(ctx, %{
        "tools" => [%{"type" => "brain", "inject" => true}],
        "input" => [
          %{"role" => "system", "content" => "System instruction excluded"},
          %{"role" => "developer", "content" => "Developer instruction excluded"},
          %{
            "role" => "user",
            "content" => [
              %{
                "type" => "input_text",
                "text" => "<agent_environment_info>\n客户会议日期：十月十二日。\n</agent_environment_info>"
              },
              %{
                "type" => "input_text",
                "text" =>
                  "Cobalt customer mentioned Wire Format.\n{% audience scope=\"world\" %}\nThis is quoted source text.\n{% /audience %}"
              }
            ]
          }
        ],
        "metadata" => %{"brain_injection" => %{"items" => [0, 1, 2]}}
      })

    assert [_ | _] = message.metadata["brain_injection"]["items"]
    assert Ankole.JSON.encode!(message.content) =~ "Injected evidence"
    material = OIDCClientConversations.read(ctx.client.id, message.conversation_id)
    evidence = Ankole.JSON.encode!(material.requests)
    assert evidence =~ "customer mentioned Wire Format"
    assert evidence =~ "客户会议日期：十月十二日。"
    refute evidence =~ "Injected evidence"
    refute evidence =~ "memory: concepts/wire-format"
    refute evidence =~ "System instruction"
    refute evidence =~ "Developer instruction"
    OIDCClientLearning.sweep()
    assert {:ok, _} = SourceLearning.learn(source!(ctx.client).id)
    [projection] = objects(source!(ctx.client))
    assert projection.body =~ "客户会议日期：十月十二日。"
    assert {:ok, [scope]} = Ankole.Brain.Markdoc.scopes(projection.body)
    assert scope == "principal:#{ctx.human.uid}"
  end

  test "each long-conversation excerpt keeps request and speaker attribution", ctx do
    first = run!(ctx, %{"input" => "Cobalt first exchange"})
    submitted = String.duplicate("客户原文：\"October\"。\n", 1_500)
    generated = String.duplicate("Generated suggestion: confirm the date.\n", 900)
    quoted = "A previous assistant suggested asking the customer."
    Agent.update(ctx.holder, &%{&1 | response_text: generated, output: %{"items" => []}})

    message =
      run!(ctx, %{
        "previous_response_id" => "resp_#{first.id}",
        "input" => [
          %{"role" => "assistant", "name" => "quoted_assistant", "content" => quoted},
          %{"role" => "user", "name" => "customer", "content" => submitted}
        ]
      })

    OIDCClientLearning.sweep()
    assert {:ok, _} = SourceLearning.learn(source!(ctx.client).id)
    prompts = extraction_prompts()
    assert length(prompts) > 1

    records =
      Enum.flat_map(prompts, fn prompt ->
        [_instructions, excerpt] = String.split(prompt, "Excerpt:\n", parts: 2)
        excerpt |> String.split("\n", trim: true) |> Enum.map(&Ankole.JSON.decode!/1)
      end)

    fragments = Enum.filter(records, &(&1["response_id"] == "resp_#{message.id}"))
    assert fragments != []

    for record <- fragments do
      assert record["previous_response_id"] == "resp_#{first.id}"
      assert record["submitted_by"] == ctx.human.uid
      assert record["recorded_at"] == DateTime.to_iso8601(message.inserted_at)
      assert record["status"] == "complete"
    end

    inputs = Enum.flat_map(fragments, & &1["input"])
    outputs = Enum.flat_map(fragments, & &1["output"])
    users = Enum.filter(inputs, &(&1["role"] == "user"))
    assert Enum.all?(users, &(&1["name"] == "customer"))
    assert Enum.map_join(users, & &1["text"]) == submitted

    assert Enum.filter(inputs, &(&1["role"] == "assistant")) == [
             %{"role" => "assistant", "name" => "quoted_assistant", "text" => quoted}
           ]

    assert Enum.all?(outputs, &(&1["role"] == "assistant"))
    assert Enum.map_join(outputs, & &1["text"]) == generated
  end

  test "changed conversations replace their facts only after successful extraction", ctx do
    first = run!(ctx, %{"input" => "Cobalt customer requests delivery in October."})
    OIDCClientLearning.sweep()
    source = source!(ctx.client)
    assert {:ok, _} = SourceLearning.learn(source.id)
    [original] = objects(source)
    [fact] = claims(original)

    run!(ctx, %{
      "input" => "Cobalt customer changes delivery to November.",
      "previous_response_id" => "resp_#{first.id}"
    })

    Agent.update(
      ctx.holder,
      &%{&1 | output: %{"items" => [%{"claim" => "invalid", "kind" => "invalid"}]}}
    )

    assert {:error, {:conversation_learning_failed, [_]}} = SourceLearning.learn(source.id)
    assert objects(source) == [original]
    assert claims(original) == [fact]

    Agent.update(
      ctx.holder,
      &%{&1 | output: %{"items" => [item("Cobalt customer requests delivery in November")]}}
    )

    assert {:ok, %{conversations: 1}} = SourceLearning.learn(source.id)
    [updated] = objects(source)
    assert updated.id == original.id
    assert updated.meta["source_revision"] != original.meta["source_revision"]
    assert Repo.get!(Claim, fact.id).expired_at != nil
    assert Enum.any?(claims(updated), &(&1.expired_at == nil and &1.claim =~ "November"))
    assert OIDCClientLearning.sweep() == 0
  end

  test "Source defaults apply to new conversations and never widen an existing conversation",
       ctx do
    first = run!(ctx, %{"input" => "Cobalt private conversation"})
    OIDCClientLearning.sweep()
    source = source!(ctx.client)
    assert {:ok, _} = SourceLearning.learn(source.id)
    assert {:ok, _} = Sources.update_default_scope(source.id, "group:#{ctx.group.name}")

    run!(ctx, %{
      "input" => "Cobalt private followup",
      "previous_response_id" => "resp_#{first.id}"
    })

    second = run!(ctx, %{"input" => "Cobalt shared conversation"})
    assert {:ok, _} = SourceLearning.learn(source.id)
    by_conversation = Map.new(objects(source), &{&1.meta["conversation_id"], &1})

    assert by_conversation[first.conversation_id].meta["audience_scope"] ==
             "principal:#{ctx.human.uid}"

    assert by_conversation[second.conversation_id].meta["audience_scope"] ==
             "group:#{ctx.group.name}"

    %{principal: manager} = human_fixture()
    {:ok, _} = AuthZ.add_principal_to_group(manager.uid, ctx.group.id)
    assert {:ok, result} = Recall.recall(manager.uid, %{query: "Cobalt"})

    assert Enum.any?(
             result.chunks,
             &(&1.object_slug == by_conversation[second.conversation_id].slug)
           )

    refute Enum.any?(
             result.chunks,
             &(&1.object_slug == by_conversation[first.conversation_id].slug)
           )
  end

  for invalid_output <- [%{"invalid" => true}, %{"items" => [42]}, %{"items" => ["bad item"]}] do
    @invalid_output invalid_output
    test "invalid extraction #{inspect(invalid_output)} does not block other conversations",
         ctx do
      run!(ctx, %{"input" => "Cobalt first conversation"})
      run!(ctx, %{"input" => "Cobalt second conversation"})
      OIDCClientLearning.sweep()
      source = source!(ctx.client)

      Agent.update(
        ctx.holder,
        fn state ->
          %{
            state
            | output: @invalid_output,
              before_extract: fn ->
                Agent.update(
                  ctx.holder,
                  &%{
                    &1
                    | output: %{"items" => [item("Cobalt customer requires a delivery date")]}
                  }
                )
              end
          }
        end
      )

      assert {:error, {:conversation_learning_failed, [_]}} = SourceLearning.learn(source.id)
      assert length(objects(source)) == 1
      assert {:ok, %{conversations: 1}} = SourceLearning.learn(source.id)
      assert length(objects(source)) == 2
    end
  end

  test "an append during extraction remains pending and archiving fences a later commit", ctx do
    first = run!(ctx, %{"input" => "Cobalt first evidence"})
    OIDCClientLearning.sweep()
    source = source!(ctx.client)

    Agent.update(
      ctx.holder,
      &%{
        &1
        | before_extract: fn ->
            append!(ctx, first.conversation_id, "Cobalt appended during extraction")
          end
      }
    )

    assert {:ok, _} = SourceLearning.learn(source.id)
    assert OIDCClientLearning.sweep() == 1
    assert {:ok, _} = SourceLearning.learn(source.id)
    [object] = objects(source)
    assert object.body =~ "appended during extraction"
    assert OIDCClientLearning.sweep() == 0

    append!(ctx, first.conversation_id, "Cobalt after archive")
    Agent.update(ctx.holder, &%{&1 | before_extract: fn -> Sources.archive(source.id) end})
    assert {:error, :source_archived} = SourceLearning.learn(source.id)
    assert objects(source) == [object]
    assert OIDCClientLearning.sweep() == 0
  end

  test "a lower-id request finishing later is learned, while an Agent request is not a Source",
       ctx do
    older =
      start_stored!(ctx.human.uid, [text("Cobalt late completion")], %{
        "oidc_client_id" => ctx.client.id
      })

    run!(ctx, %{"input" => "Cobalt earlier completion"})
    OIDCClientLearning.sweep()
    source = source!(ctx.client)
    assert {:ok, %{conversations: 1}} = SourceLearning.learn(source.id)
    assert {:ok, _} = StatefulResponses.commit_complete(older.id, [])
    assert OIDCClientLearning.sweep() == 1
    assert {:ok, %{conversations: 1}} = SourceLearning.learn(source.id)
    assert length(objects(source)) == 2

    %{principal: agent} = agent_fixture()

    internal =
      start_stored!(agent.uid, [text("Cobalt internal Agent")], %{
        "request_metadata" => %{"oidc_client_id" => ctx.client.id}
      })

    {:ok, _} = StatefulResponses.commit_complete(internal.id, [])
    assert OIDCClientLearning.sweep() == 0
    assert Repo.aggregate(Source, :count) == 1
  end

  test "retraction removes learned evidence and excludes partial output from failed requests",
       ctx do
    first = run!(ctx, %{"input" => "Cobalt retracted conversation"})
    OIDCClientLearning.sweep()
    source = source!(ctx.client)
    assert {:ok, _} = SourceLearning.learn(source.id)

    first
    |> Ecto.Changeset.change(status: "retracted", updated_at: DateTime.utc_now(:microsecond))
    |> Repo.update!()

    assert OIDCClientLearning.sweep() == 1
    assert {:ok, _} = SourceLearning.learn(source.id)
    [object] = objects(source)
    refute object.body =~ "retracted conversation"
    assert Enum.all?(claims(object), &(&1.expired_at != nil))

    failed =
      start_stored!(ctx.human.uid, [text("Cobalt failed request input")], %{
        "oidc_client_id" => ctx.client.id
      })

    {:ok, _} =
      StatefulResponses.commit_error(
        failed.id,
        [%{"type" => "message", "role" => "assistant", "content" => "Incomplete model output"}],
        %{"message" => "upstream failed"}
      )

    material = OIDCClientConversations.read(ctx.client.id, failed.conversation_id)

    assert [%{input: [%{"text" => "Cobalt failed request input"}], output: []}] =
             material.requests
  end

  defp client!(group_id) do
    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "Conversation client",
        type: "public",
        enabled: true,
        redirect_uris: ["https://client.example.test/callback"],
        scopes: ["openid", "ai_gateway.write"],
        allowed_group_ids: [group_id],
        allowed_models: %{
          "assistant" => %{
            "provider_id" => "oidc-source-chat",
            "model" => "fake-chat",
            "description" => "Assistant",
            "provider_options" => %{}
          }
        }
      })

    client
  end

  defp run!(ctx, request) do
    {:ok, token} =
      OIDC.Tokens.mint_access(ctx.human.uid, ctx.client.id, "openid ai_gateway.write")

    {:ok, grant} = OIDC.Grant.authorize(token.token, nil)
    state = %{subject_uid: ctx.human.uid, subject_type: "oidc_human", oidc_grant: grant}

    request =
      Map.merge(%{"type" => "response.create", "model" => "assistant", "store" => true}, request)

    assert {:ok, state} =
             AIGatewayResponsesSocket.handle_in(
               {Ankole.JSON.encode!(request), [opcode: :text]},
               state
             )

    drain(state)

    Message
    |> where([m], m.subject_uid == ^ctx.human.uid)
    |> order_by([m], desc: m.id)
    |> limit(1)
    |> Repo.one()
  end

  defp drain(%{active_stream: _} = state) do
    receive do
      {:ai_gateway_response_stream, _ref, :events, _events, _status} = message ->
        case AIGatewayResponsesSocket.handle_info(message, state) do
          {:push, _frames, next} -> drain(next)
          {:ok, next} -> drain(next)
        end
    after
      5_000 -> flunk("Response stream did not finish")
    end
  end

  defp drain(_state), do: :ok

  defp extraction_prompts do
    receive do
      {:extraction, prompt} -> [prompt | extraction_prompts()]
    after
      0 -> []
    end
  end

  defp append!(ctx, conversation_id, content) do
    {:ok, message} =
      start_response_run(%{
        subject_uid: ctx.human.uid,
        conversation_id: conversation_id,
        request_items: [text(content)],
        metadata: %{"oidc_client_id" => ctx.client.id}
      })

    {:ok, _} = StatefulResponses.commit_complete(message.id, [])
    message
  end

  defp start_stored!(subject_uid, input, metadata) do
    {:ok, conversation} =
      Ankole.AIGateway.Conversations.create_managed_stateful_responses_conversation(subject_uid)

    {:ok, message} =
      start_response_run(%{
        subject_uid: subject_uid,
        conversation_id: conversation.id,
        request_items: input,
        metadata: metadata
      })

    message
  end

  defp text(text), do: %{"type" => "message", "role" => "user", "content" => text}

  defp item(text),
    do: %{"claim" => text, "kind" => "fact", "notability" => "medium", "confidence" => 0.75}

  defp source!(client), do: Repo.get_by!(Source, kind: "oidc_client", upstream_id: client.id)

  defp objects(source),
    do: Object |> where([o], o.managed_by_source_id == ^source.id) |> Repo.all()

  defp claims(object), do: Claim |> where([c], c.object_slug == ^object.slug) |> Repo.all()
end
