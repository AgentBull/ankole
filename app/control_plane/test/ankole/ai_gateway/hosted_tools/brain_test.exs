defmodule Ankole.AIGateway.HostedTools.BrainTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.CompactionRender
  alias Ankole.AIGateway.HostedTools.Brain
  alias Ankole.AIGateway.ProgramExecution
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.AIGateway.ToolSearch
  alias Ankole.AIGateway.ToolSearch.StreamLoop
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Tools

  setup do
    {:ok, _result} = SchemaPacks.install_packs([])

    %{principal: owner} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})

    {:ok, object} =
      Objects.create_object(
        %{
          slug: "concepts/wire-format",
          type: "concept",
          title: "Wire Format",
          body: "Notes about the wire format."
        },
        agent.uid
      )

    {:ok, %{claim: _fact}} =
      Claims.write_fact(
        %{
          object_slug: object.slug,
          claim: "The wire format carries dated facts",
          kind: "fact",
          holder: "world",
          audience_scope: "world",
          notability: "medium",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        agent.uid
      )

    {:ok, _alias} = Ankole.Brain.Links.add_alias(object.slug, "Wire Format")

    %{agent: agent, object: object}
  end

  describe "declaration" do
    test "reads the operation subset and the injection flag" do
      assert {:ok, nil} =
               Brain.declaration(%{"tools" => [%{"type" => "function", "name" => "x"}]})

      assert {:ok, %{operations: operations, inject?: false}} =
               Brain.declaration(%{"tools" => [%{"type" => "brain"}]})

      assert operations == Tools.operations()

      assert {:ok, %{operations: ["recall", "get_page"], inject?: true}} =
               Brain.declaration(%{
                 "tools" => [
                   %{"type" => "brain", "operations" => ["get_page", "recall"], "inject" => true}
                 ]
               })
    end

    test "rejects duplicate, unknown, and malformed declarations" do
      assert {:error, {:invalid_brain_tool, :duplicate_declaration}} =
               Brain.declaration(%{"tools" => [%{"type" => "brain"}, %{"type" => "brain"}]})

      assert {:error, {:invalid_brain_tool, {:unknown_field, "scope"}}} =
               Brain.declaration(%{"tools" => [%{"type" => "brain", "scope" => "world"}]})

      assert {:error, {:invalid_brain_tool, :unknown_operation}} =
               Brain.declaration(%{"tools" => [%{"type" => "brain", "operations" => ["erase"]}]})

      assert {:error, {:invalid_brain_tool, :invalid_inject}} =
               Brain.declaration(%{"tools" => [%{"type" => "brain", "inject" => "yes"}]})
    end
  end

  describe "plan" do
    test "declares the catalog as root functions and reserves their names", context do
      request = %{
        "model" => "openrouter/openai/gpt-5.6",
        "tools" => [
          %{"type" => "function", "name" => "shell", "parameters" => %{}},
          %{"type" => "brain"}
        ],
        "input" => []
      }

      assert {:ok, %Brain.Plan{} = brain, stripped} = Brain.split(context.agent.uid, request)
      assert brain.subject_uid == context.agent.uid
      assert brain.context.querier_uid == context.agent.uid
      refute Enum.any?(ToolSearch.list_tools(stripped), &(&1["type"] == "brain"))

      assert {:ok, provider_request, %ToolSearch.Plan{brain: ^brain} = plan} =
               ToolSearch.plan(stripped, brain: brain)

      assert ToolSearch.response_stream_required?(plan)

      names = provider_request |> ToolSearch.list_tools() |> Enum.map(& &1["name"])
      assert names == ["shell" | Tools.operations()]

      colliding = %{
        "model" => "openrouter/openai/gpt-5.6",
        "tools" => [%{"type" => "function", "name" => "recall", "parameters" => %{}}],
        "input" => []
      }

      assert {:error, _reason} = ToolSearch.plan(colliding, brain: brain)
    end

    test "a first-party provider keeps its native tools and still gains the hosted catalog",
         context do
      request = %{"model" => "openai/gpt-5.6", "tools" => [%{"type" => "brain"}], "input" => []}
      assert {:ok, brain, stripped} = Brain.split(context.agent.uid, request)

      assert {:ok, provider_request, %ToolSearch.Plan{brain: ^brain, execution: nil}} =
               ToolSearch.plan(stripped, brain: brain, native_tools?: true)

      assert provider_request |> ToolSearch.list_tools() |> length() == length(Tools.operations())

      assert {:ok, _request, nil} =
               ToolSearch.plan(%{"input" => []}, brain: nil, native_tools?: true)
    end

    test "an actor event of another Agent makes the declaration invalid", context do
      %{principal: other} = agent_fixture()
      event = insert_actor_event!(other.uid)

      request = %{
        "model" => "openrouter/openai/gpt-5.6",
        "tools" => [%{"type" => "brain"}],
        "metadata" => %{"actor_event_id" => event.id},
        "input" => []
      }

      assert {:error, {:invalid_brain_tool, :actor_event_not_owned}} =
               Brain.split(context.agent.uid, request)
    end
  end

  describe "stream round" do
    test "executes a recall inside the response and answers the next provider round", context do
      {loop, brain} = loop!(context.agent.uid, %{"type" => "brain"})

      {loop, emitted} =
        Enum.reduce(call_events("recall", ~s({"query":"wire format dated facts"})), {loop, []}, fn
          event, {loop, emitted} ->
            case StreamLoop.observe(loop, event) do
              {:emit, event, loop} -> {loop, emitted ++ [event]}
              {:suppress, loop} -> {loop, emitted}
            end
        end)

      # The argument deltas of the synthesized call stay private; the public
      # stream keeps the lifecycle and the rewritten call.
      assert Enum.map(emitted, & &1["type"]) == ["response.created", "response.output_item.done"]
      done = List.last(emitted)

      assert %{"type" => "brain_call", "operation" => "recall", "call_id" => "call-1"} =
               done["item"]

      assert done["item"]["arguments"] == %{"query" => "wire format dated facts"}

      terminal = %{
        "id" => "resp_p",
        "status" => "completed",
        "output" => [call_item("recall", ~s({"query":"wire format dated facts"}))]
      }

      assert {:local, [job], loop_context, loop} =
               StreamLoop.intercept_terminal(loop, "response.completed", terminal)

      assert job.kind == :brain
      assert job.operation == "recall"
      assert job.context.querier_uid == context.agent.uid
      assert loop_context.brain_jobs == [job]

      handler_id = "hosted-brain-#{System.unique_integer([:positive])}"
      test_pid = self()

      :ok =
        :telemetry.attach(
          handler_id,
          [:ankole, :ai_gateway, :hosted_brain],
          fn _event, measurements, metadata, _config ->
            send(test_pid, {:hosted_brain_telemetry, measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      outcomes =
        ProgramExecution.run_jobs([job], fn _code, _bindings, _memo -> {:error, :unused} end)

      assert [%{call_id: "call-1", outcome: %{kind: :brain, status: :completed}}] = outcomes

      # Operators count and time hosted operations without seeing their content.
      assert_receive {:hosted_brain_telemetry, %{count: 1, latency_ms: latency_ms},
                      %{operation: "recall", result: "success", failure_reason: nil} = metadata}

      assert metadata.subject_uid == context.agent.uid
      assert is_integer(latency_ms) and latency_ms >= 0

      assert {:round, continuation, [output_item], _loop} =
               StreamLoop.complete_local_effect(loop, loop_context, outcomes)

      assert %{"type" => "brain_output", "call_id" => "call-1", "status" => "completed"} =
               output_item

      assert [claim | _rest] = output_item["output"]["claims"]
      assert claim["claim"] =~ "dated facts"

      assert %{"type" => "function_call_output", "call_id" => "call-1", "output" => text} =
               List.last(continuation["input"])

      assert {:ok, decoded} = Ankole.JSON.decode(text)
      assert decoded["claims"] != []

      # The pair is a registered family: history analysis, replay projection,
      # and the built-in budget all know it.
      assert %ResponseItems.History{error: nil} =
               ResponseItems.analyze_history([done["item"], output_item])

      assert {:handled, %{"type" => "function_call", "name" => "recall", "call_id" => "call-1"}} =
               Brain.provider_history_item(done["item"])

      assert {:handled, %{"type" => "function_call_output", "call_id" => "call-1"}} =
               Brain.provider_history_item(output_item)

      assert ResponseItems.budget_role(done["item"]) == :gateway_effect
      assert ResponseItems.executable_call?(done["item"])
      assert CompactionRender.item_text(done["item"], []) =~ "brain_call operation=recall"
      assert CompactionRender.item_text(output_item, []) =~ "brain_output operation=recall"
      assert is_nil(brain.context.write_fence)
    end

    test "a failed operation answers its own call without failing the response", context do
      {loop, _brain} = loop!(context.agent.uid, %{"type" => "brain"})

      terminal = %{
        "id" => "resp_p",
        "status" => "completed",
        "output" => [
          call_item("delta", ~s({"since":"last tuesday"})),
          call_item("recall", "not json", "call-2")
        ]
      }

      assert {:local, jobs, loop_context, loop} =
               StreamLoop.intercept_terminal(loop, "response.completed", terminal)

      assert [%{operation: "delta"}, %{operation: "recall", preflight_outcome: %{}}] = jobs

      outcomes =
        ProgramExecution.run_jobs(jobs, fn _code, _bindings, _memo -> {:error, :unused} end)

      assert {:round, _continuation, [delta_output, recall_output], _loop} =
               StreamLoop.complete_local_effect(loop, loop_context, outcomes)

      assert delta_output["status"] == "failed"
      assert delta_output["output"]["error"] == "brain_operation_failed"
      assert recall_output["status"] == "failed"
      assert recall_output["output"]["error"] == "brain_invalid_arguments"
    end

    test "a restricted declaration leaves other operations to the client", context do
      {loop, _brain} =
        loop!(context.agent.uid, %{"type" => "brain", "operations" => ["recall", "get_page"]})

      names = loop.downstream_tools |> Enum.map(& &1["name"])
      assert names == ["recall", "get_page"]

      terminal = %{
        "id" => "resp_p",
        "status" => "completed",
        "output" => [call_item("remember", ~s({"claim":"x","kind":"fact","provenance":"y"}))]
      }

      # `remember` is not declared, so the call stays an ordinary client call.
      assert {:finalize, [%{"type" => "function_call", "name" => "remember"}], [], _loop} =
               StreamLoop.intercept_terminal(loop, "response.completed", terminal)
    end

    test "an exhausted tool budget removes the hosted operations", context do
      {loop, _brain} = loop!(context.agent.uid, %{"type" => "brain"})
      request = StreamLoop.disable_budgeted_effects(loop, loop.provider_request)
      assert ToolSearch.list_tools(request) == []
    end
  end

  describe "injection" do
    test "injects the pack at conversation start and again after a compaction checkpoint",
         context do
      conversation = insert_conversation!(context.agent.uid)
      request = injecting_request()
      input = [user_message("Tell me about the Wire Format")]

      injected = Brain.inject_stateful(context.agent.uid, request, conversation, input)
      assert [pack, prompt] = injected
      assert pack["role"] == "user"
      assert pack_text(pack) =~ "<recalled_memory>"
      assert pack_text(pack) =~ "entity: concepts/wire-format — Wire Format (concept)"
      assert pack_text(pack) =~ "The wire format carries dated facts"
      assert environment_text(prompt) =~ "memory: concepts/wire-format — Wire Format (concept)"

      # Later requests of the same conversation get the pointers only.
      conversation = Repo.reload!(conversation)

      assert [prompt_only] =
               Brain.inject_stateful(context.agent.uid, request, conversation, input)

      assert environment_text(prompt_only) =~ "memory: concepts/wire-format"

      # A compaction checkpoint newer than the recorded slot reopens it once.
      insert_checkpoint!(context.agent.uid, conversation.id)

      assert [_pack, _prompt] =
               Brain.inject_stateful(context.agent.uid, request, conversation, input)

      conversation = Repo.reload!(conversation)

      assert [_prompt_only] =
               Brain.inject_stateful(context.agent.uid, request, conversation, input)
    end

    test "reopens the slot for a retry of the same actor event", context do
      conversation = insert_conversation!(context.agent.uid)
      event = insert_actor_event!(context.agent.uid)
      request = injecting_request(%{"actor_event_id" => event.id})
      input = [user_message("Wire Format again")]

      assert [_pack, _prompt] =
               Brain.inject_stateful(context.agent.uid, request, conversation, input)

      conversation = Repo.reload!(conversation)

      assert [_pack, _prompt] =
               Brain.inject_stateful(context.agent.uid, request, conversation, input)

      successor = insert_actor_event!(context.agent.uid)
      later = injecting_request(%{"actor_event_id" => successor.id})
      conversation = Repo.reload!(conversation)
      assert [_prompt_only] = Brain.inject_stateful(context.agent.uid, later, conversation, input)
    end

    test "pointer lines join the existing environment block and name only what the message names",
         context do
      conversation = insert_conversation!(context.agent.uid)
      request = injecting_request()

      environment = %{
        "type" => "input_text",
        "text" => "<agent_environment_info>\nsend_at: now\n</agent_environment_info>"
      }

      input = [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [
            environment,
            %{"type" => "input_text", "text" => "how did the Wire Format land?"}
          ]
        }
      ]

      assert [_pack, prompt] =
               Brain.inject_stateful(context.agent.uid, request, conversation, input)

      [environment_part, text_part] = prompt["content"]

      assert environment_part["text"] ==
               "<agent_environment_info>\nsend_at: now\nmemory: concepts/wire-format — Wire Format (concept)\n</agent_environment_info>"

      assert text_part["text"] == "how did the Wire Format land?"

      conversation = Repo.reload!(conversation)
      unrelated = [user_message("please book a room for Thursday")]

      assert ^unrelated =
               Brain.inject_stateful(context.agent.uid, request, conversation, unrelated)
    end

    test "requires the injection flag and leaves the input alone on failure", context do
      conversation = insert_conversation!(context.agent.uid)
      input = [user_message("Wire Format")]

      assert ^input =
               Brain.inject_stateful(
                 context.agent.uid,
                 %{"tools" => [%{"type" => "brain"}]},
                 conversation,
                 input
               )

      assert ^input = Brain.inject_stateful(context.agent.uid, %{}, conversation, input)

      %{principal: other} = agent_fixture()
      foreign = insert_actor_event!(other.uid)

      assert ^input =
               Brain.inject_stateful(
                 context.agent.uid,
                 injecting_request(%{"actor_event_id" => foreign.id}),
                 conversation,
                 input
               )
    end

    test "a Human subject is injected as its own participant", context do
      %{principal: human} = human_fixture()
      conversation = insert_conversation!(human.uid)
      input = [user_message("What do we know about the Wire Format?")]

      assert [pack, _prompt] =
               Brain.inject_stateful(human.uid, injecting_request(), conversation, input)

      assert pack_text(pack) =~ "entity: concepts/wire-format"
      assert context.object.slug == "concepts/wire-format"
    end
  end

  defp loop!(subject_uid, declaration) do
    request = %{
      "model" => "openrouter/openai/gpt-5.6",
      "tools" => [declaration],
      "input" => [user_message("hello")]
    }

    {:ok, brain, stripped} = Brain.split(subject_uid, request)
    {:ok, provider_request, plan} = ToolSearch.plan(stripped, brain: brain)
    {StreamLoop.new(%{plan: plan, provider_request: provider_request}), brain}
  end

  defp call_events(name, arguments, call_id \\ "call-1") do
    [
      %{
        "type" => "response.created",
        "sequence_number" => 0,
        "response" => %{"id" => "resp_p"}
      },
      %{
        "type" => "response.output_item.added",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => %{"type" => "function_call", "name" => name, "id" => "fc_1"}
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => 2,
        "output_index" => 0,
        "item" => call_item(name, arguments, call_id)
      }
    ]
  end

  defp call_item(name, arguments, call_id \\ "call-1") do
    %{
      "type" => "function_call",
      "id" => "fc_" <> call_id,
      "name" => name,
      "call_id" => call_id,
      "status" => "completed",
      "arguments" => arguments
    }
  end

  defp injecting_request(metadata \\ %{}) do
    %{
      "model" => "openrouter/openai/gpt-5.6",
      "tools" => [%{"type" => "brain", "inject" => true}],
      "metadata" => metadata,
      "input" => []
    }
  end

  defp user_message(text) do
    %{
      "type" => "message",
      "role" => "user",
      "content" => [%{"type" => "input_text", "text" => text}]
    }
  end

  defp pack_text(%{"content" => [%{"text" => text}]}), do: text

  defp environment_text(%{"content" => [%{"text" => text} | _rest]}), do: text

  defp insert_conversation!(subject_uid) do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%Ankole.AIGateway.Schemas.Conversation{
      id: Ecto.UUID.generate(),
      subject_uid: subject_uid,
      conversation_key: "session-#{System.unique_integer([:positive])}",
      metadata: %{},
      inserted_at: now,
      updated_at: now
    })
  end

  defp insert_checkpoint!(subject_uid, conversation_id) do
    # Strictly after the recorded slot timestamp, so the comparison is stable.
    at = DateTime.add(DateTime.utc_now(:microsecond), 1, :second)

    Repo.insert!(%Ankole.AIGateway.Schemas.Message{
      subject_uid: subject_uid,
      conversation_id: conversation_id,
      type: "checkpoint",
      status: "complete",
      content: [%{"id" => "cmp_#{Ecto.UUID.generate()}", "type" => "compaction_artifact"}],
      metadata: %{},
      inserted_at: at,
      updated_at: at
    })
  end

  defp insert_actor_event!(agent_uid) do
    Repo.insert!(
      struct!(Ankole.SignalsGateway.ActorEvent, %{
        agent_uid: agent_uid,
        binding_name: "test-binding",
        session_id: "session-#{System.unique_integer([:positive])}",
        source_event_id: "event-#{System.unique_integer([:positive])}",
        signal_channel_id: nil,
        type: "signal",
        available_at: DateTime.utc_now(:microsecond),
        queue_sequence: System.unique_integer([:positive]),
        sender_key: nil,
        payload: %{}
      })
    )
  end
end
