defmodule Ankole.Brain.StageBTest do
  use Ankole.AIGatewayCase

  alias Ecto.Adapters.SQL.Sandbox

  import Ankole.PrincipalsFixtures
  import Ankole.SignalsGatewayFixtures, only: [binding_fixture: 3]

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.Conversations
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.Conversation, as: AIGatewayConversation
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.AppConfigure
  alias Ankole.AuthZ.Group
  alias Ankole.Brain
  alias Ankole.Brain.Citations
  alias Ankole.Brain.Sources
  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming.StageB
  alias Ankole.Brain.Jobs.CuratePrincipal
  alias Ankole.Brain.Jobs.EnqueuePrincipalDreaming
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Schemas.Cursor
  alias Ankole.Brain.Schemas.EntryBlock
  alias Ankole.Brain.Schemas.EntryRelation
  alias Ankole.Brain.Scope
  alias Ankole.SignalsGateway.{ActorEvent, AdapterContext, BindingMembership, Channel}
  alias Ankole.SignalsGateway.Entry, as: SignalEntry
  alias Ankole.SignalsGateway.Projection
  alias Ankole.SystemConfig

  @base_time ~U[2026-07-13 00:00:00.000000Z]

  setup do
    :ok = Brain.ensure_registered()
    :ok
  end

  test "does not relearn outbound Agent messages as user evidence" do
    %{principal: agent} = agent_fixture()

    outbound =
      visible_signal_material!(agent.uid, "The Agent produced this reply", "stage-b-outbound")

    outbound
    |> SignalEntry.changeset(%{ai_message_id: Ecto.UUID.generate()})
    |> Repo.update!()

    configure_model!(agent, fn _request -> response_summary(empty_plan()) end)
    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :no_new_material, material_count: 0}} = StageB.run(agent.uid)
  end

  test "does not feed explicit source-learning outcomes back into principal dreaming" do
    %{principal: agent} = agent_fixture()

    _source_run =
      task_outcome_material!(agent.uid, "stage-b-source-learning", "Learn the retained PDF",
        type: "brain.source.learn"
      )

    configure_model!(agent, fn _request -> response_summary(empty_plan()) end)
    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :no_new_material, material_count: 0}} = StageB.run(agent.uid)
  end

  test "a person entry can preserve the signal speaker principal uid" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()

    _message =
      visible_dm_signal_material!(
        agent.uid,
        peer.uid,
        "I prefer concise status updates",
        "stage-b-person-principal"
      )

    configure_model!(agent, fn request ->
      assert [material] = request_payload(request)["materials"]
      assert material["speaker"] == "Alice"
      assert material["speaker_principal_uid"] == peer.uid

      response_summary(%{
        "operations" => [
          %{
            "operation" => "create_entry",
            "name" => "Alice",
            "type" => "person",
            "summary" => "Alice's stable preferences",
            "aliases" => [],
            "properties" => %{"principal_uid" => material["speaker_principal_uid"]}
          }
        ],
        "skill_updates" => []
      })
    end)

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 1})

    assert {:ok, %{status: :completed, operation_count: 1}} = StageB.run(agent.uid)

    {:ok, scope} = Scope.for_store(agent.uid, "dm:#{peer.uid}")
    assert {:ok, [entry]} = Knowledge.list_entries(scope, limit: 20)
    assert entry.type == "person"
    assert entry.properties["principal_uid"] == peer.uid
  end

  test "mutation failures do not advance the baseline and a new entry can receive a dreaming block" do
    %{principal: agent} = agent_fixture()
    source = visible_signal_material!(agent.uid, "I now prefer vegetables", "stage-b-diet")

    plan = %{
      "operations" => [
        %{
          "operation" => "create_entry",
          "client_ref" => "diet",
          "name" => "Diet preference",
          "type" => "preference",
          "summary" => "Current dietary preference",
          "aliases" => [],
          "properties" => %{}
        },
        %{
          "operation" => "append_block",
          "entry_ref" => "diet",
          "body" => "Alice said “I now prefer vegetables” on the observed date. src:material_1"
        }
      ],
      "skill_updates" => []
    }

    configure_model!(agent, fn _request -> response_summary(plan) end)
    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 1})

    assert {:error, :dreaming_mutation_budget_exceeded} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["signal_document_id"]

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 2})

    assert {:ok,
            %{
              status: :completed,
              material_count: 1,
              operation_count: 2,
              skill_update_count: 0
            }} = StageB.run(agent.uid)

    assert principal_cursor!(agent.uid).metadata["signal_document_id"] == source.document_id

    {:ok, scope} = Scope.for_store(agent.uid, "shared")
    assert {:ok, [entry]} = Knowledge.list_entries(scope, limit: 20)
    assert entry.name == "Diet preference"
    assert {:ok, projection} = Knowledge.open(scope, entry.id, block_limit: :all)

    assert [%{body: body, author_kind: :dreaming}] = projection.blocks
    assert body =~ "I now prefer vegetables"
    assert body =~ "src:#{source.document_id}"

    assert {:ok, %{status: :no_new_material, material_count: 0}} = StageB.run(agent.uid)
  end

  test "an unprojectable task window advances the cursor instead of pinning it" do
    %{principal: agent} = agent_fixture()

    undeclared =
      for index <- 1..3 do
        unroutable_task_outcome!(
          agent.uid,
          "stage-b-undeclared",
          "external api message #{index}"
        )
      end

    configure_model!(agent, fn _request -> response_summary(empty_plan()) end)
    configure_dreaming!(agent.uid, agent.uid, %{"material_limit" => 3})

    assert {:ok, %{status: :no_new_material, material_count: 0}} = StageB.run(agent.uid)

    skipped = principal_cursor!(agent.uid)
    assert skipped.metadata["task_actor_event_id"] == List.last(undeclared).id

    declared = task_outcome_material!(agent.uid, "stage-b-declared", "durable preference appears")

    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["task_actor_event_id"] == declared.id
  end

  test "an unprojectable task window is skipped even when signal material commits" do
    %{principal: agent} = agent_fixture()

    undeclared =
      unroutable_task_outcome!(agent.uid, "stage-b-undeclared-mixed", "external only")

    signal = visible_signal_material!(agent.uid, "durable signal fact", "stage-b-mixed-hash")

    configure_model!(agent, fn _request -> response_summary(empty_plan()) end)
    configure_dreaming!(agent.uid, agent.uid, %{})

    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)

    metadata = principal_cursor!(agent.uid).metadata
    assert metadata["task_actor_event_id"] == undeclared.id
    assert metadata["signal_document_id"] == signal.document_id
  end

  test "an invalid curator mutation is retried before the material cursor advances" do
    %{principal: agent} = agent_fixture()
    message = task_outcome_material!(agent.uid, "stage-b-curator-retry", "durable topic")
    attempts = :atomics.new(1, signed: false)

    configure_model!(agent, fn request ->
      system =
        request.body["input"]
        |> Enum.find(&(&1["role"] == "system"))
        |> get_in(["content", Access.at(0), "text"])

      case :atomics.add_get(attempts, 1, 1) do
        1 ->
          assert system =~ "edit_block: operation, entry_name, block_position, and non-empty body"

          response_summary(%{
            "operations" => [
              %{
                "operation" => "edit_block",
                "body" => "The model omitted its block target."
              }
            ],
            "skill_updates" => []
          })

        2 ->
          assert system =~ "Retry correction from the control plane"
          assert system =~ "edit_block requires entry_name, block_position, and a non-empty body"

          response_summary(%{
            "operations" => [
              %{
                "operation" => "create_entry",
                "name" => "Invalid empty block",
                "type" => "topic",
                "initial_body" => ""
              }
            ],
            "skill_updates" => []
          })

        _retry ->
          assert system =~ "create_entry requires non-empty name and type"
          assert system =~ "does not accept initial_body"
          response_summary(empty_plan())
      end
    end)

    configure_dreaming!(agent.uid, agent.uid)
    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert :atomics.get(attempts, 1) == 3
    assert principal_cursor!(agent.uid).metadata["task_actor_event_id"] == message.id
  end

  test "an unknown source reference is corrected on the next curator attempt" do
    %{principal: agent} = agent_fixture()

    message =
      visible_signal_material!(
        agent.uid,
        "Source reference retry is a durable lesson.",
        "stage-b-source-ref-retry"
      )

    attempts = :atomics.new(1, signed: false)

    configure_model!(agent, fn request ->
      system =
        request.body["input"]
        |> Enum.find(&(&1["role"] == "system"))
        |> get_in(["content", Access.at(0), "text"])

      source_ref =
        case :atomics.add_get(attempts, 1, 1) do
          1 ->
            "source_999"

          _retry ->
            assert system =~ "rejected at operations[1]"
            assert system =~ "Use only material_N references shown in materials"
            "material_1"
        end

      response_summary(%{
        "operations" => [
          %{
            "operation" => "create_entry",
            "client_ref" => "source-ref-retry",
            "name" => "Source reference retry",
            "type" => "topic"
          },
          %{
            "operation" => "append_block",
            "entry_ref" => "source-ref-retry",
            "body" => "Durable lesson. src:#{source_ref}"
          }
        ],
        "skill_updates" => []
      })
    end)

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 2})

    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert :atomics.get(attempts, 1) == 2
    assert principal_cursor!(agent.uid).metadata["signal_document_id"] == message.document_id
  end

  test "a relation plan links the target in the final source body before commit" do
    %{principal: agent} = agent_fixture()

    _material =
      visible_signal_material!(
        agent.uid,
        "Source Subject is owned by Target Subject.",
        "stage-b-relation-link"
      )

    {:ok, scope} = Scope.for_store(agent.uid, "shared")
    source_id = create_knowledge_entry!(scope, agent.uid, "Source Subject")
    target_id = create_knowledge_entry!(scope, agent.uid, "Target Subject")

    assert {:ok, %{results: [%{block_id: _block_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: source_id,
                 expected_entry_lock_version: 1,
                 body: "Target Subject owns this work."
               },
               %{kind: :human, uid: agent.uid}
             )

    attempts = :atomics.new(1, signed: false)

    configure_model!(
      agent,
      fn request ->
        system =
          request.body["input"]
          |> Enum.find(&(&1["role"] == "system"))
          |> get_in(["content", Access.at(0), "text"])

        case :atomics.add_get(attempts, 1, 1) do
          1 ->
            assert system =~ "A body link without add_relation is incomplete"

            response_summary(%{
              "operations" => [
                %{
                  "operation" => "add_relation",
                  "entry_name" => "Source Subject",
                  "target_entry_name" => "Target Subject",
                  "predicate" => "owned by"
                }
              ],
              "skill_updates" => []
            })

          _retry ->
            assert system =~ "source entry's final body must contain [[Target Subject]]"

            response_summary(%{
              "operations" => [
                %{
                  "operation" => "edit_block",
                  "entry_name" => "Source Subject",
                  "block_position" => 0,
                  "body" => "[[Target Subject]] owns Source Subject. src:material_1"
                },
                %{
                  "operation" => "add_relation",
                  "entry_name" => "Source Subject",
                  "target_entry_name" => "Target Subject",
                  "predicate" => "owned by"
                }
              ],
              "skill_updates" => []
            })
        end
      end,
      locator: fn request ->
        system =
          request.body["input"]
          |> Enum.find(&(&1["role"] == "system"))
          |> get_in(["content", Access.at(0), "text"])

        assert system =~ "emit at least one topic for each endpoint"
        [indexed] = request_payload(request)["material_index"]

        response_summary(%{
          "material_refs" => [indexed["material_ref"]],
          "topics" => [
            %{
              "query" => "Source Subject",
              "material_refs" => [indexed["material_ref"]]
            },
            %{
              "query" => "Target Subject",
              "material_refs" => [indexed["material_ref"]]
            }
          ]
        })
      end
    )

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 2})

    assert {:ok, %{status: :completed, operation_count: 2}} = StageB.run(agent.uid)
    assert :atomics.get(attempts, 1) == 2

    assert %EntryRelation{predicate: "owned by", target_entry_id: ^target_id} =
             Repo.get_by!(EntryRelation, source_entry_id: source_id)

    assert {:ok, %{blocks: [%{body: body}]}} = Knowledge.open(scope, source_id, block_limit: :all)
    assert body =~ "[[Target Subject]]"
  end

  test "the principal cursor is a cross-node single-flight lease and advances only after commit" do
    %{principal: agent} = agent_fixture()
    message = task_outcome_material!(agent.uid, "stage-b-single-flight", "one external fact")
    test_pid = self()

    configure_model!(agent, fn request ->
      send(test_pid, {:curator_waiting, self(), request})

      receive do
        :release_curator -> response_summary(empty_plan())
      end
    end)

    configure_dreaming!(agent.uid, agent.uid)

    task = Task.async(fn -> StageB.run(agent.uid) end)
    assert_receive {:curator_waiting, upstream_pid, _request}, 5_000

    cursor = principal_cursor!(agent.uid)
    assert is_binary(cursor.metadata["stage_b_run_id"])
    refute cursor.metadata["task_actor_event_id"]
    assert {:ok, %{status: :already_running}} = StageB.run(agent.uid)

    assert {:snooze, 60} =
             CuratePrincipal.perform(%Oban.Job{args: %{"principal_uid" => agent.uid}})

    send(upstream_pid, :release_curator)
    assert {:ok, %{status: :completed, material_count: 1}} = Task.await(task, 10_000)

    cursor = principal_cursor!(agent.uid)
    assert cursor.metadata["task_actor_event_id"] == message.id
    refute cursor.metadata["stage_b_run_id"]
    refute_receive {:curator_waiting, _pid, _request}, 100
  end

  test "token budgeting consumes only a complete material prefix" do
    %{principal: agent} = agent_fixture()

    first =
      task_outcome_material!(agent.uid, "stage-b-token-budget", "a", completed_at: @base_time)

    second =
      task_outcome_material!(agent.uid, "stage-b-token-budget", String.duplicate("long ", 25_000),
        completed_at: DateTime.add(@base_time, 1, :second)
      )

    configure_model!(agent, fn _request -> response_summary(empty_plan()) end)
    configure_dreaming!(agent.uid, agent.uid, %{"token_limit" => 20_000})

    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["task_actor_event_id"] == first.id

    assert {:error, :dreaming_token_limit_too_small} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["task_actor_event_id"] == first.id

    configure_dreaming!(agent.uid, agent.uid, %{"token_limit" => 0})
    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["task_actor_event_id"] == second.id
  end

  test "locator can skip noise while the cursor consumes the complete scanned batch" do
    %{principal: agent} = agent_fixture()

    _first =
      task_outcome_material!(agent.uid, "stage-b-locator-prefix", "first material",
        completed_at: @base_time
      )

    second =
      task_outcome_material!(agent.uid, "stage-b-locator-prefix", "second material",
        completed_at: DateTime.add(@base_time, 1, :second)
      )

    configure_model!(
      agent,
      fn request ->
        payload = curator_payload(request)
        assert Enum.map(payload["materials"], & &1["material_ref"]) == ["material_2"]
        response_summary(empty_plan())
      end,
      locator: fn request ->
        payload = request_payload(request)

        assert Enum.map(payload["material_index"], & &1["material_ref"]) == [
                 "material_1",
                 "material_2"
               ]

        response_summary(%{
          "material_refs" => ["material_2"],
          "topics" => [%{"query" => "second material", "material_refs" => ["material_2"]}]
        })
      end
    )

    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :completed, material_count: 2, operation_count: 0}} =
             StageB.run(agent.uid)

    cursor = principal_cursor!(agent.uid)
    assert cursor.metadata["task_actor_event_id"] == second.id
    assert {:ok, %{status: :no_new_material}} = StageB.run(agent.uid)
  end

  test "an irrelevant scanned batch advances without calling the curator" do
    %{principal: agent} = agent_fixture()

    first =
      task_outcome_material!(agent.uid, "stage-b-empty-locator", "routine acknowledgement",
        completed_at: @base_time
      )

    second =
      task_outcome_material!(agent.uid, "stage-b-empty-locator", "another acknowledgement",
        completed_at: DateTime.add(@base_time, 1, :second)
      )

    test_pid = self()

    configure_model!(
      agent,
      fn request ->
        send(test_pid, {:unexpected_curator, request})
        response_summary(empty_plan())
      end,
      locator: fn _request ->
        response_summary(%{"material_refs" => [], "topics" => []})
      end
    )

    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :completed, material_count: 2, operation_count: 0}} =
             StageB.run(agent.uid)

    assert principal_cursor!(agent.uid).metadata["task_actor_event_id"] == second.id
    refute_receive {:unexpected_curator, _request}, 100
    assert {:ok, %{status: :no_new_material}} = StageB.run(agent.uid)
    assert first.id != second.id
  end

  test "locator and curator requests use phase-specific structured output contracts" do
    %{principal: agent} = agent_fixture()
    _message = task_outcome_material!(agent.uid, "stage-b-response-format", "durable preference")
    test_pid = self()

    configure_model!(
      agent,
      fn request ->
        send(test_pid, {:stage_b_response_format, :curator, request.body["text"]})
        response_summary(empty_plan())
      end,
      locator: fn request ->
        assert request.body["reasoning"] == %{"effort" => "high"}
        send(test_pid, {:stage_b_response_format, :locator, request.body["text"]})
        select_all_locator_response(request)
      end
    )

    configure_dreaming!(agent.uid, agent.uid)
    assert {:ok, %{status: :completed}} = StageB.run(agent.uid)

    assert_receive {:stage_b_response_format, :locator,
                    %{
                      "format" => %{
                        "type" => "json_schema",
                        "name" => "brain_stage_b_locator",
                        "strict" => true,
                        "schema" => locator_schema
                      }
                    }}

    assert locator_schema["required"] == ["material_refs", "topics"]

    assert_receive {:stage_b_response_format, :curator,
                    %{
                      "format" => %{
                        "type" => "json_schema",
                        "name" => "brain_stage_b_curator",
                        "strict" => false,
                        "schema" => curator_schema
                      }
                    }}

    assert curator_schema["required"] == ["operations", "skill_updates"]

    operation_names =
      get_in(curator_schema, [
        "properties",
        "operations",
        "items",
        "properties",
        "operation",
        "enum"
      ])

    assert "create_entry" in operation_names
    assert "remove_relation" in operation_names
  end

  test "a completed actor turn becomes one task outcome without raw tool arguments or outputs" do
    %{principal: agent} = agent_fixture()

    actor_event =
      task_outcome_material!(agent.uid, "stage-b-task-evidence", "Remember the workflow lesson",
        completed_at: @base_time,
        response_rows: [
          [
            %{
              "type" => "function_call",
              "call_id" => "call-1",
              "name" => "web_search",
              "arguments" => ~s({"query":"RATE_CUT_QUERY"})
            }
          ],
          [
            %{
              "type" => "function_call_output",
              "call_id" => "call-1",
              "output" => "SECRET_TOOL_OUTPUT_1"
            },
            %{
              "type" => "function_call",
              "call_id" => "call-2",
              "name" => "web_search",
              "arguments" => ~s({"query":"VALUATION_QUERY"})
            }
          ],
          [
            %{
              "type" => "function_call_output",
              "call_id" => "call-2",
              "output" => "SECRET_TOOL_OUTPUT_2"
            },
            %{
              "type" => "function_call",
              "call_id" => "call-3",
              "name" => "memory_search",
              "arguments" => ~s({"query":"PRIVATE_RECALL_QUERY"})
            }
          ],
          [
            %{
              "type" => "function_call_output",
              "call_id" => "call-3",
              "output" => "SECRET_TOOL_OUTPUT_3"
            },
            %{
              "type" => "message",
              "role" => "assistant",
              "content" => [%{"type" => "output_text", "text" => "Workflow captured."}]
            }
          ]
        ]
      )

    assert {:ok, _timezone} = SystemConfig.put_timezone("Asia/Singapore")
    on_exit(fn -> AppConfigure.delete_global(SystemConfig.timezone_definition()) end)

    configure_model!(
      agent,
      fn request ->
        payload = request_payload(request)
        assert [material] = payload["materials"]
        assert material["material_ref"] == "material_1"
        assert material["kind"] == "task_outcome"
        assert material["completed_at"] == "2026-07-13 08:00:00 (Asia/Singapore)"

        assert material["request"] == [
                 %{"speaker" => "Alice", "text" => "Remember the workflow lesson"}
               ]

        assert material["final_response"] == "Workflow captured."

        assert material["tools_used"] == [
                 %{"name" => "memory_search", "call_count" => 1, "result_count" => 1},
                 %{"name" => "web_search", "call_count" => 2, "result_count" => 2}
               ]

        encoded = Ankole.JSON.encode!(material)
        refute encoded =~ "function_call"
        refute encoded =~ "RATE_CUT_QUERY"
        refute encoded =~ "VALUATION_QUERY"
        refute encoded =~ "PRIVATE_RECALL_QUERY"
        refute encoded =~ "SECRET_TOOL_OUTPUT"
        refute encoded =~ "call-1"
        refute encoded =~ actor_event.id
        refute Map.has_key?(material, "store_key")
        response_summary(empty_plan())
      end,
      locator: fn request ->
        payload = request_payload(request)
        assert [material] = payload["material_index"]
        assert material["material_ref"] == "material_1"
        assert material["kind"] == "task_outcome"
        assert material["preview"] =~ "Remember the workflow lesson"

        encoded = Ankole.JSON.encode!(material)
        refute encoded =~ "RATE_CUT_QUERY"
        refute encoded =~ "SECRET_TOOL_OUTPUT"
        select_all_locator_response(request)
      end
    )

    configure_dreaming!(agent.uid, agent.uid)
    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["task_actor_event_id"] == actor_event.id
  end

  test "a complete AIGateway row without a completed Actor turn is not Dreaming evidence" do
    %{principal: agent} = agent_fixture()

    {:ok, conversation} =
      Conversations.ensure_conversation(agent.uid, "stage-b-raw-response",
        metadata: %{"brain" => %{"visibility" => "self"}}
      )

    %Message{}
    |> Message.changeset(%{
      subject_uid: agent.uid,
      conversation_id: conversation.id,
      type: "message",
      role: "assistant",
      status: "complete",
      content: [
        %{
          "type" => "function_call",
          "call_id" => "raw-call",
          "name" => "web_search",
          "arguments" => ~s({"query":"RAW_RESPONSE_QUERY"})
        },
        %{
          "type" => "function_call_output",
          "call_id" => "raw-call",
          "output" => "RAW_RESPONSE_OUTPUT"
        }
      ],
      metadata: %{}
    })
    |> Repo.insert!()

    configure_model!(agent, fn _request -> response_summary(empty_plan()) end)
    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :no_new_material, material_count: 0}} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["task_actor_event_id"]
  end

  test "token budget counts locator and curator requests across shared and private stores" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()

    shared_message =
      visible_signal_material!(agent.uid, "small shared material", "stage-b-budget-shared",
        observed_at: @base_time
      )

    private_message =
      visible_dm_signal_material!(
        agent.uid,
        peer.uid,
        String.duplicate("private ", 25_000),
        "stage-b-budget-private",
        observed_at: DateTime.add(@base_time, 1, :second)
      )

    test_pid = self()

    configure_model!(
      agent,
      fn request ->
        send(test_pid, {:budgeted_request, request})
        response_summary(empty_plan())
      end,
      locator: fn request ->
        send(test_pid, {:budgeted_request, request})
        select_all_locator_response(request)
      end
    )

    configure_dreaming!(agent.uid, agent.uid, %{"token_limit" => 20_000})

    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)

    assert principal_cursor!(agent.uid).metadata["signal_document_id"] ==
             shared_message.document_id

    requests = receive_budgeted_requests([])
    assert length(requests) == 2
    assert Enum.sum(Enum.map(requests, &request_token_cost/1)) <= 20_000

    assert {:error, :dreaming_token_limit_too_small} = StageB.run(agent.uid)

    assert principal_cursor!(agent.uid).metadata["signal_document_id"] ==
             shared_message.document_id

    configure_dreaming!(agent.uid, agent.uid, %{"token_limit" => 0})
    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)

    assert principal_cursor!(agent.uid).metadata["signal_document_id"] ==
             private_message.document_id
  end

  test "curator output rejects noncanonical operations and envelopes without advancing" do
    %{principal: agent} = agent_fixture()
    _message = task_outcome_material!(agent.uid, "stage-b-json-envelope", "external material")
    configure_dreaming!(agent.uid, agent.uid)
    json = Ankole.JSON.encode!(empty_plan())

    invalid_sentinel = %{
      "operations" => [%{"operation" => "nil", "reason" => "not sure"}],
      "skill_updates" => []
    }

    configure_model!(agent, fn _request -> response_summary(invalid_sentinel) end)

    assert {:error,
            {:invalid_dreaming_operation,
             %{store_key: "self", index: 0, operation: "nil", fields: fields}}} =
             StageB.run(agent.uid)

    assert fields == ["operation", "reason"]
    refute principal_cursor!(agent.uid).metadata["task_actor_event_id"]

    alias_operation = %{
      "operations" => [
        %{
          "op" => "create_entry",
          "name" => "Compatibility residue",
          "type" => "topic"
        }
      ],
      "skill_updates" => []
    }

    configure_model!(agent, fn _request -> response_summary(alias_operation) end)

    assert {:error,
            {:invalid_dreaming_operation,
             %{store_key: "self", index: 0, operation: nil, fields: alias_fields}}} =
             StageB.run(agent.uid)

    assert alias_fields == ["name", "op", "type"]
    refute principal_cursor!(agent.uid).metadata["task_actor_event_id"]

    configure_model!(agent, fn _request -> response_text("Explanation:\n#{json}") end)
    assert {:error, _invalid_json} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["task_actor_event_id"]

    multiple = "```json\n#{json}\n```\n```json\n#{json}\n```"
    configure_model!(agent, fn _request -> response_text(multiple) end)
    assert {:error, _invalid_multiple_payload} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["task_actor_event_id"]
  end

  test "source hashes are rechecked under the write transaction after model inference" do
    %{principal: agent} = agent_fixture()
    source = visible_signal_material!(agent.uid, "source before edit", "hash-v1")
    test_pid = self()

    plan = %{
      "operations" => [
        %{
          "operation" => "create_entry",
          "client_ref" => "source-check",
          "name" => "Source check",
          "type" => "topic",
          "summary" => "",
          "aliases" => [],
          "properties" => %{}
        },
        %{
          "operation" => "append_block",
          "entry_ref" => "source-check",
          "body" => "Quoted evidence src:material_1"
        }
      ],
      "skill_updates" => []
    }

    configure_model!(agent, fn request ->
      assert [material] = request_payload(request)["materials"]
      assert material["material_ref"] == "material_1"
      assert material["kind"] == "signal_message"
      assert material["speaker"] == "Alice"
      assert material["text"] == "source before edit"
      assert material["observed_at"] =~ ~r/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \(.+\)$/
      refute Map.has_key?(material, "content_hash")
      refute Map.has_key?(material, "source_entry_id")
      refute Map.has_key?(material, "store_key")
      send(test_pid, {:source_curator_waiting, self(), request})

      receive do
        :release_source_curator -> response_summary(plan)
      end
    end)

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 2})

    task = Task.async(fn -> StageB.run(agent.uid) end)
    assert_receive {:source_curator_waiting, upstream_pid, _request}, 5_000

    source
    |> Ecto.Changeset.change(
      text: "source after edit",
      content_hash: "hash-v2"
    )
    |> Repo.update!()

    send(upstream_pid, :release_source_curator)
    assert {:ok, %{status: :completed}} = Task.await(task, 10_000)

    {:ok, scope} = Scope.for_store(agent.uid, "shared")
    assert {:ok, [entry]} = Knowledge.list_entries(scope, limit: 20)
    assert {:ok, projection} = Knowledge.open(scope, entry.id, block_limit: :all)
    assert [%{body: body, author_kind: :dreaming}] = projection.blocks
    assert body =~ "原文已变化"
    refute body =~ "src:"
  end

  test "source revalidation never waits on a SignalsGateway row writer" do
    %{principal: agent} = agent_fixture()
    _task_material = task_outcome_material!(agent.uid, "stage-b-nonblocking-source", "workflow")
    external = external_signal_entry!()
    on_exit(fn -> delete_external_signal_entry!(external) end)
    test_pid = self()

    {:ok, scope} = Scope.for_store(agent.uid, "self")
    history_id = create_knowledge_entry!(scope, agent.uid, "External source history")

    assert {:ok, %{results: [%{block_id: block_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "append_block",
                 entry_id: history_id,
                 expected_entry_lock_version: 1,
                 body: "Prior external evidence"
               },
               %{kind: :human, uid: agent.uid}
             )

    block =
      block_id
      |> then(&Repo.get!(EntryBlock, &1))
      |> Ecto.Changeset.change(body: "Prior external evidence src:#{external.entry.document_id}")
      |> Repo.update!()

    assert :ok = Citations.reindex(Repo, block)

    plan = %{
      "operations" => [
        %{
          "operation" => "create_entry",
          "client_ref" => "nonblocking-source",
          "name" => "Nonblocking source",
          "type" => "topic",
          "summary" => "",
          "aliases" => [],
          "properties" => %{}
        },
        %{
          "operation" => "append_block",
          "entry_ref" => "nonblocking-source",
          "body" => "Unverified source src:source_1"
        }
      ],
      "skill_updates" => []
    }

    configure_model!(
      agent,
      fn request ->
        payload = request_payload(request)
        encoded = Ankole.JSON.encode!(payload)
        assert encoded =~ "src:source_1"
        refute encoded =~ external.entry.document_id
        send(test_pid, :nonblocking_source_curator_called)
        response_summary(plan)
      end,
      locator: fn request ->
        [material] = request_payload(request)["material_index"]

        response_summary(%{
          "material_refs" => [material["material_ref"]],
          "topics" => [
            %{
              "query" => "External source history",
              "material_refs" => [material["material_ref"]]
            }
          ]
        })
      end
    )

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 2})

    writer =
      Task.async(fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Repo.transact(fn repo ->
            source =
              repo.one!(
                from entry in SignalEntry,
                  where: entry.document_id == ^external.entry.document_id,
                  lock: "FOR UPDATE"
              )

            {:ok, source} =
              source
              |> Ecto.Changeset.change(text: "source after edit", content_hash: "hash-v2")
              |> repo.update()

            send(test_pid, {:source_update_pending, self()})

            receive do
              :commit_source_update -> {:ok, source}
            end
          end)
        end)
      end)

    assert_receive {:source_update_pending, writer_pid}, 5_000

    dreaming = Task.async(fn -> StageB.run(agent.uid) end)
    assert_receive :nonblocking_source_curator_called, 5_000

    try do
      assert {:ok, %{status: :completed, operation_count: 2}} =
               Task.await(dreaming, 5_000)
    after
      send(writer_pid, :commit_source_update)
    end

    assert {:ok, %SignalEntry{content_hash: "hash-v2"}} = Task.await(writer, 5_000)
  end

  test "shared and private materials are curated in isolated calls with one global mutation budget" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()

    shared_message =
      visible_signal_material!(agent.uid, "SHARED_ONLY_MARKER", "stage-b-mixed-shared",
        observed_at: @base_time
      )

    dm_message =
      visible_dm_signal_material!(
        agent.uid,
        peer.uid,
        "PRIVATE_ONLY_MARKER",
        "stage-b-mixed-dm",
        observed_at: DateTime.add(@base_time, 1, :second)
      )

    test_pid = self()

    configure_model!(agent, fn request ->
      payload = curator_payload(request)
      encoded = Ankole.JSON.encode!(payload)

      store_label =
        cond do
          encoded =~ "SHARED_ONLY_MARKER" -> "shared"
          encoded =~ "PRIVATE_ONLY_MARKER" -> "dm:#{peer.uid}"
        end

      send(test_pid, {:store_curator_payload, store_label, payload})

      name = if store_label == "shared", do: "Shared topic", else: "Private topic"

      response_summary(%{
        "operations" => [
          %{
            "operation" => "create_entry",
            "name" => name,
            "type" => "topic",
            "summary" => "",
            "aliases" => [],
            "properties" => %{}
          }
        ],
        "skill_updates" => []
      })
    end)

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 1})
    assert {:error, :dreaming_mutation_budget_exceeded} = StageB.run(agent.uid)

    first_payloads = receive_store_payloads!()
    assert_store_payload_isolation!(first_payloads, peer.uid)

    cursor = principal_cursor!(agent.uid)
    refute cursor.metadata["task_actor_event_id"]
    {:ok, all_scope} = Scope.for_console(agent.uid, :all)
    assert {:ok, []} = Knowledge.list_entries(all_scope, limit: 20)

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 2})

    assert {:ok, %{status: :completed, material_count: 2, operation_count: 2, run_id: run_id}} =
             StageB.run(agent.uid)

    second_payloads = receive_store_payloads!()
    assert_store_payload_isolation!(second_payloads, peer.uid)

    cursor = principal_cursor!(agent.uid)
    assert cursor.metadata["signal_document_id"] == dm_message.document_id
    refute cursor.metadata["signal_document_id"] == shared_message.document_id

    assert {:ok, entries} = Knowledge.list_entries(all_scope, limit: 20)

    assert MapSet.new(Enum.map(entries, &{&1.store_key, &1.name})) ==
             MapSet.new([{"shared", "Shared topic"}, {"dm:#{peer.uid}", "Private topic"}])

    traces =
      AIGatewayConversation
      |> where([conversation], like(conversation.conversation_key, ^"brain.dreaming:#{run_id}:%"))
      |> Repo.all()

    assert length(traces) == 2

    assert traces
           |> Map.new(&{&1.metadata["brain"]["visibility"], &1.metadata["brain"]})
           |> then(fn by_visibility ->
             by_visibility["shared"] == %{"visibility" => "shared"} and
               by_visibility["dm"]["peer_uid"] == peer.uid and
               by_visibility["dm"]["channel_kind"] == "im_dm"
           end)
  end

  test "a captured confidential route survives a later binding change" do
    %{principal: agent} = agent_fixture()

    message =
      visible_signal_material!(
        agent.uid,
        "captured confidential evidence",
        "stage-b-captured-confidential-route"
      )

    captured_store = "channel:#{message.signal_channel_id}"

    message
    |> SignalEntry.changeset(%{
      metadata:
        Projection.put_entry_brain_store_route(message.metadata, agent.uid, captured_store)
    })
    |> Repo.update!()

    configure_model!(agent, fn _request ->
      response_summary(%{
        "operations" => [
          %{
            "operation" => "create_entry",
            "name" => "Captured confidential topic",
            "type" => "topic",
            "summary" => "",
            "aliases" => [],
            "properties" => %{}
          }
        ],
        "skill_updates" => []
      })
    end)

    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :completed, operation_count: 1}} = StageB.run(agent.uid)
    {:ok, all_scope} = Scope.for_console(agent.uid, :all)
    assert {:ok, entries} = Knowledge.list_entries(all_scope, limit: 20)

    assert Enum.any?(entries, fn entry ->
             entry.name == "Captured confidential topic" and entry.store_key == captured_store
           end)
  end

  test "private dreaming calls cannot mutate the global skill overlay" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()

    _message =
      visible_dm_signal_material!(
        agent.uid,
        peer.uid,
        "private correction",
        "stage-b-private-skill"
      )

    test_pid = self()

    configure_model!(agent, fn request ->
      payload = curator_payload(request)
      send(test_pid, {:private_skill_payload, payload})

      response_summary(%{
        "operations" => [],
        "skill_updates" => [
          %{"skill_name" => "research", "mode" => "append", "content" => "secret lesson"}
        ]
      })
    end)

    configure_dreaming!(agent.uid, agent.uid)
    assert {:error, :private_skill_updates_forbidden} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["task_actor_event_id"]

    assert_receive {:private_skill_payload, payload}, 1_000
    assert payload["enabled_skills"] == []
    refute Enum.any?(payload["materials"], &Map.has_key?(&1, "store_key"))
  end

  test "private dreaming calls cannot mutate self or shared knowledge" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()

    _message =
      visible_dm_signal_material!(
        agent.uid,
        peer.uid,
        "private preference",
        "stage-b-private-global-knowledge"
      )

    configure_model!(agent, fn _request ->
      response_summary(%{
        "operations" => [
          %{
            "operation" => "create_entry",
            "name" => "Leaked private memo",
            "type" => "agent_system_pinned_memo",
            "summary" => "",
            "aliases" => [],
            "properties" => %{}
          }
        ],
        "skill_updates" => []
      })
    end)

    configure_dreaming!(agent.uid, agent.uid)

    assert {:error,
            {:dreaming_store_boundary_violation,
             %{
               source_store_key: "dm:" <> peer_uid,
               target_store_key: "self",
               operation: "create_entry"
             }}} = StageB.run(agent.uid)

    assert peer_uid == peer.uid
    {:ok, self_scope} = Scope.for_store(agent.uid, "self")
    assert {:ok, []} = Knowledge.list_entries(self_scope, store_key: "self", limit: 20)
  end

  test "a store boundary rejection is explained to the next curator attempt" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()

    _message =
      visible_dm_signal_material!(
        agent.uid,
        peer.uid,
        "private preference",
        "stage-b-private-boundary-retry"
      )

    attempts = :atomics.new(1, signed: false)

    configure_model!(agent, fn request ->
      system =
        request.body["input"]
        |> Enum.find(&(&1["role"] == "system"))
        |> get_in(["content", Access.at(0), "text"])

      case :atomics.add_get(attempts, 1, 1) do
        1 ->
          response_summary(%{
            "operations" => [
              %{
                "operation" => "create_entry",
                "name" => "Leaked private memo",
                "type" => "agent_system_pinned_memo"
              }
            ],
            "skill_updates" => []
          })

        _retry ->
          assert system =~ "rejected at operations[0]"
          assert system =~ "tried to write store \"self\""
          assert system =~ "not writable for evidence from store \"dm:"
          response_summary(empty_plan())
      end
    end)

    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert :atomics.get(attempts, 1) == 2

    {:ok, self_scope} = Scope.for_store(agent.uid, "self")
    assert {:ok, []} = Knowledge.list_entries(self_scope, store_key: "self", limit: 20)
  end

  test "private dreaming cannot edit a visible shared entry" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()
    {:ok, shared_scope} = Scope.for_store(agent.uid, "shared")

    assert {:ok, %{results: [%{entry_id: shared_entry_id}]}} =
             Knowledge.apply_operations(
               shared_scope,
               %{
                 operation: "create_entry",
                 name: "Shared boundary target",
                 type: "topic",
                 summary: "shared value",
                 aliases: [],
                 properties: %{},
                 initial_body: "Shared boundary target shared value"
               },
               %{kind: :agent, uid: agent.uid}
             )

    _message =
      visible_dm_signal_material!(
        agent.uid,
        peer.uid,
        "Shared boundary target private correction",
        "stage-b-private-shared-update"
      )

    locator = fn request ->
      refs = request_payload(request)["material_index"] |> Enum.map(& &1["material_ref"])

      response_summary(%{
        "material_refs" => refs,
        "topics" => [%{"query" => "Shared boundary target", "material_refs" => refs}]
      })
    end

    configure_model!(
      agent,
      fn _request ->
        response_summary(%{
          "operations" => [
            %{
              "operation" => "set_summary",
              "entry_name" => "Shared boundary target",
              "summary" => "private value leaked into shared"
            }
          ],
          "skill_updates" => []
        })
      end,
      locator: locator
    )

    configure_dreaming!(agent.uid, agent.uid)

    assert {:error,
            {:dreaming_store_boundary_violation,
             %{
               source_store_key: "dm:" <> peer_uid,
               target_store_key: "shared",
               operation: "set_summary"
             }}} = StageB.run(agent.uid)

    assert peer_uid == peer.uid

    assert {:ok, %{entry: %{summary: "shared value"}}} =
             Knowledge.open(shared_scope, shared_entry_id, block_limit: :all)
  end

  test "curator receives only dynamic run context and local model-facing timestamps" do
    %{principal: agent} = agent_fixture()

    _message =
      task_outcome_material!(agent.uid, "stage-b-policy", "corrected workflow lesson",
        completed_at: ~U[2026-07-13 20:30:00.000000Z]
      )

    test_pid = self()

    on_exit(fn ->
      AppConfigure.delete_global(SystemConfig.timezone_definition())
      AppConfigure.delete_global(Config.knowledge_definition())
    end)

    assert {:ok, _timezone} = SystemConfig.put_timezone("Asia/Singapore")
    assert {:ok, knowledge_config} = Config.knowledge()

    assert {:ok, _stored} =
             AppConfigure.put_global(
               Config.knowledge_definition(),
               Map.put(knowledge_config, "pinned_memo_max_tokens", 777)
             )

    configure_model!(agent, fn request ->
      send(test_pid, {:policy_payload, request_payload(request)})
      response_summary(empty_plan())
    end)

    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :completed}} =
             StageB.run(agent.uid, now: ~U[2026-07-13 20:30:00.000000Z])

    assert_receive {:policy_payload, payload}, 1_000

    assert payload["run_context"] == %{
             "local_date" => "2026-07-14",
             "pinned_memo_max_tokens" => 777,
             "timezone" => "Asia/Singapore"
           }

    refute Map.has_key?(payload, "curation_policy")
    refute Map.has_key?(payload, "locator_topics")
    assert [%{"completed_at" => "2026-07-14 04:30:00 (Asia/Singapore)"}] = payload["materials"]
  end

  test "overlapping skill append requires replace and does not consume material" do
    %{principal: agent} = agent_fixture()
    message = task_outcome_material!(agent.uid, "stage-b-overlap", "repeated PDF lesson")
    existing = "Large PDF review -> verify each rendered page before delivery."

    assert {:ok, overlay} = Library.skill_append(agent.uid, "nano-pdf", existing)

    plan = %{
      "operations" => [],
      "skill_updates" => [
        %{"skill_name" => "nano-pdf", "mode" => "append", "content" => existing}
      ]
    }

    configure_model!(agent, fn request ->
      skill =
        request
        |> request_payload()
        |> Map.fetch!("enabled_skills")
        |> Enum.find(&(&1["skill_name"] == "nano-pdf"))

      assert Map.keys(skill) |> Enum.sort() ==
               ["current_overlay", "description", "skill_name"]

      assert skill["current_overlay"] == existing
      refute Ankole.JSON.encode!(skill) =~ "content_hash"
      refute Ankole.JSON.encode!(skill) =~ "skill_root"
      response_summary(plan)
    end)

    configure_dreaming!(agent.uid, agent.uid)

    assert {:error, :dreaming_skill_append_requires_replace} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["task_actor_event_id"] == message.id

    assert {:ok, current} = Library.skill_overlay(agent.uid, "nano-pdf")
    assert current.id == overlay.id
    assert current.overlay_json == %{"text" => existing}
  end

  test "skill append conflicts with a concurrent overlay change and does not consume material" do
    %{principal: agent} = agent_fixture()
    message = task_outcome_material!(agent.uid, "stage-b-skill-cas", "new PDF lesson")
    assert {:ok, _overlay} = Library.skill_append(agent.uid, "nano-pdf", "Existing guidance.")
    test_pid = self()

    plan = %{
      "operations" => [],
      "skill_updates" => [
        %{
          "skill_name" => "nano-pdf",
          "mode" => "append",
          "content" => "Scanned PDF -> inspect OCR output before delivery."
        }
      ]
    }

    configure_model!(agent, fn _request ->
      send(test_pid, {:skill_curator_waiting, self()})

      receive do
        :release_skill_curator -> response_summary(plan)
      end
    end)

    configure_dreaming!(agent.uid, agent.uid)
    task = Task.async(fn -> StageB.run(agent.uid) end)
    assert_receive {:skill_curator_waiting, upstream_pid}, 5_000

    assert {:ok, _overlay} =
             Library.skill_append(agent.uid, "nano-pdf", "Concurrent operator guidance.")

    send(upstream_pid, :release_skill_curator)
    assert {:error, :skill_overlay_conflict} = Task.await(task, 10_000)
    refute principal_cursor!(agent.uid).metadata["task_actor_event_id"] == message.id

    assert {:ok, current} = Library.skill_overlay(agent.uid, "nano-pdf")
    assert current.overlay_json["text"] =~ "Concurrent operator guidance."
    refute current.overlay_json["text"] =~ "Scanned PDF"
  end

  test "locator topics retrieve an old relevant entry instead of the latest directory slice" do
    %{principal: agent} = agent_fixture()
    _message = task_outcome_material!(agent.uid, "stage-b-relevant-knowledge", "verdant quokka")
    {:ok, scope} = Scope.for_store(agent.uid, "self")

    relevant_id = create_knowledge_entry!(scope, agent.uid, "Verdant quokka dossier")

    Repo.update_all(
      from(entry in Ankole.Brain.Schemas.Entry, where: entry.id == ^relevant_id),
      set: [updated_at: ~U[2020-01-01 00:00:00.000000Z]]
    )

    for index <- 1..45 do
      create_knowledge_entry!(scope, agent.uid, "Recent unrelated entry #{index}")
    end

    test_pid = self()

    configure_model!(
      agent,
      fn request ->
        send(test_pid, {:knowledge_payload, request_payload(request)})
        response_summary(empty_plan())
      end,
      locator: fn request ->
        [material] = request_payload(request)["material_index"]

        response_summary(%{
          "material_refs" => [material["material_ref"]],
          "topics" => [
            %{
              "query" => "Verdant quokka dossier",
              "material_refs" => [material["material_ref"]]
            }
          ]
        })
      end
    )

    configure_dreaming!(agent.uid, agent.uid)
    assert {:ok, %{status: :completed}} = StageB.run(agent.uid)
    assert_receive {:knowledge_payload, payload}, 1_000

    context =
      Enum.find(payload["current_knowledge"], fn context ->
        get_in(context, ["entry", "name"]) == "Verdant quokka dossier"
      end)

    assert context
    refute Map.has_key?(context["entry"], "id")
    refute Map.has_key?(context["entry"], "store_key")
    refute Map.has_key?(context["entry"], "lock_version")
  end

  test "curator operations use the exact projection fence supplied by the server" do
    %{principal: agent} = agent_fixture()

    _message =
      task_outcome_material!(agent.uid, "stage-b-projection-fence", "verdant quokka update")

    {:ok, scope} = Scope.for_store(agent.uid, "self")
    entry_id = create_knowledge_entry!(scope, agent.uid, "Verdant quokka dossier")

    configure_model!(
      agent,
      fn request ->
        context =
          request
          |> request_payload()
          |> Map.fetch!("current_knowledge")
          |> Enum.find(&(get_in(&1, ["entry", "name"]) == "Verdant quokka dossier"))

        refute Map.has_key?(context["entry"], "id")
        refute Map.has_key?(context["entry"], "lock_version")
        refute Map.has_key?(context["entry"], "store_key")

        response_summary(%{
          "operations" => [
            %{
              "operation" => "set_summary",
              "entry_name" => "Verdant quokka dossier",
              "summary" => "Current verdant quokka evidence"
            }
          ],
          "skill_updates" => []
        })
      end,
      locator: fn request ->
        [material] = request_payload(request)["material_index"]

        response_summary(%{
          "material_refs" => [material["material_ref"]],
          "topics" => [
            %{
              "query" => "Verdant quokka dossier",
              "material_refs" => [material["material_ref"]]
            }
          ]
        })
      end
    )

    configure_dreaming!(agent.uid, agent.uid)
    assert {:ok, %{status: :completed, operation_count: 1}} = StageB.run(agent.uid)
    assert {:ok, %{entry: entry}} = Knowledge.open(scope, entry_id, block_limit: :all)
    assert entry.summary == "Current verdant quokka evidence"
  end

  test "the minute poll enqueues one microbatch after silence or backlog" do
    %{principal: agent} = agent_fixture()
    _human = human_fixture()
    material_time = ~U[2026-07-13 20:00:00.000000Z]

    _first =
      task_outcome_material!(agent.uid, "stage-b-microbatch-first", "first durable lesson",
        completed_at: material_time
      )

    configure_dreaming!(agent.uid, agent.uid, %{
      "curation_silence_minutes" => 30,
      "curation_backlog_rows" => 2
    })

    {:ok, config} = Config.dreaming(agent.uid)
    refute StageB.eligible?(agent.uid, config, DateTime.add(material_time, 29, :minute))
    assert StageB.eligible?(agent.uid, config, DateTime.add(material_time, 30, :minute))

    before = %Oban.Job{args: %{"now" => "2026-07-13T20:29:00Z"}}
    backlog_due = %Oban.Job{args: %{"now" => "2026-07-13T20:29:31Z"}}

    assert :ok = EnqueuePrincipalDreaming.perform(before)
    assert [] = all_enqueued(worker: CuratePrincipal)

    _second =
      task_outcome_material!(agent.uid, "stage-b-microbatch-second", "second durable lesson",
        completed_at: ~U[2026-07-13 20:29:30.000000Z]
      )

    assert StageB.eligible?(agent.uid, config, ~U[2026-07-13 20:29:31.000000Z])
    assert :ok = EnqueuePrincipalDreaming.perform(backlog_due)
    assert :ok = EnqueuePrincipalDreaming.perform(backlog_due)

    assert [%Oban.Job{args: first_args}] = all_enqueued(worker: CuratePrincipal)
    assert first_args["principal_uid"] == agent.uid
    assert Map.keys(first_args) == ["principal_uid"]
  end

  test "an incomplete principal curation job stays unique for its complete lifetime" do
    %{principal: agent} = agent_fixture()

    assert {:ok, first} =
             %{principal_uid: agent.uid}
             |> CuratePrincipal.new()
             |> Oban.insert()

    one_hour_ago = DateTime.add(DateTime.utc_now(:microsecond), -1, :hour)

    assert {1, nil} =
             Repo.update_all(
               from(job in Oban.Job, where: job.id == ^first.id),
               set: [inserted_at: one_hour_ago]
             )

    assert {:ok, second} =
             %{principal_uid: agent.uid}
             |> CuratePrincipal.new()
             |> Oban.insert()

    assert second.conflict?
    assert second.id == first.id
    assert [_job] = all_enqueued(worker: CuratePrincipal)
  end

  test "Stage B rejects a human owner instead of accepting an unused enable override" do
    %{principal: human} = human_fixture()

    assert {:error, :brain_dreaming_requires_agent} = Config.dreaming(human.uid)
    assert {:error, :brain_dreaming_requires_agent} = StageB.run(human.uid)
  end

  test "the next Stage B run compacts an over-budget resident memo" do
    %{principal: agent} = agent_fixture()
    test_pid = self()

    configure_model!(
      agent,
      fn _request -> response_summary(empty_plan()) end,
      memo: fn request ->
        send(test_pid, {:memo_compaction_request, request})

        {:json, 200,
         %{
           "output_text" =>
             "When deployment fails, stop and report the exact error before retrying."
         }}
      end
    )

    configure_dreaming!(agent.uid, agent.uid)
    assert {:ok, knowledge_config} = Config.knowledge()

    assert {:ok, _stored} =
             AppConfigure.put_global(
               Config.knowledge_definition(),
               Map.put(knowledge_config, "pinned_memo_max_tokens", 20)
             )

    on_exit(fn -> AppConfigure.delete_global(Config.knowledge_definition()) end)
    {:ok, scope} = Scope.for_store(agent.uid, "self")

    assert {:ok, source} =
             Sources.capture(
               scope,
               %{
                 kind: "file",
                 title: "Resident memo source",
                 original_name: "resident-memo.txt",
                 content: "Deployment failure rule."
               },
               agent.uid
             )

    assert {:ok, %{results: [%{entry_id: memo_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: "Resident Memo",
                 type: "agent_system_pinned_memo",
                 initial_body:
                   String.duplicate("repeat this operational rule with excess prose ", 40) <>
                     "(src:#{source.document_id})"
               },
               %{kind: :agent, uid: agent.uid}
             )

    assert {:ok, %{status: :no_new_material, material_count: 0, memo_compaction: :compacted}} =
             StageB.run(agent.uid)

    assert_receive {:memo_compaction_request, request}
    assert request.body["max_output_tokens"] == 20

    assert request.body
           |> get_in(["input", Access.at(0), "content", Access.at(0), "text"])
           |> String.contains?("long-term memory system (codename Brain)")

    compaction_input =
      get_in(request.body, ["input", Access.at(1), "content", Access.at(0), "text"])

    refute compaction_input =~ source.document_id
    refute compaction_input =~ "src:"

    assert {:ok, %{blocks: [%{body: compacted}]}} =
             Knowledge.open(scope, memo_id, block_limit: :all)

    assert compacted ==
             "When deployment fails, stop and report the exact error before retrying."

    assert Ankole.Kernel.estimate_o200k_base_tokens(compacted) <= 20
  end

  defp configure_model!(agent, curator_fun, opts \\ []) do
    locator_fun = Keyword.get(opts, :locator, &select_all_locator_response/1)

    memo_fun =
      Keyword.get(opts, :memo, fn request ->
        flunk("unexpected memo request: #{inspect(request)}")
      end)

    base_url =
      start_upstream_server(fn request ->
        case stage_b_phase(request) do
          :locator -> locator_fun.(request)
          :curator -> curator_fun.(request)
          :memo -> memo_fun.(request)
        end
      end)

    provider_id = "brain-stage-b-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               base_url: "#{base_url}/v1",
               connection_options: %{
                 "api_key" => "sk-stage-b-test",
                 "transport" => %{"http_versions" => ["h1"]}
               }
             })

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "light", %{
               provider_id: provider_id,
               model: "gpt-stage-b-test"
             })
  end

  defp configure_dreaming!(owner_uid, _model_uid, overrides \\ %{}) do
    assert {:ok, config} = Config.dreaming(owner_uid)

    config =
      config
      |> Map.put("enabled", true)
      |> Map.merge(overrides)

    assert {:ok, _config} =
             AppConfigure.put_for_agent(owner_uid, Config.dreaming_definition(), config)
  end

  defp task_outcome_material!(owner_uid, key, text, opts \\ []) do
    brain = Keyword.get(opts, :brain, %{"visibility" => "self"})
    event_type = Keyword.get(opts, :type, "im.message.addressed")

    {:ok, conversation} =
      Conversations.ensure_conversation(owner_uid, key, metadata: %{"brain" => brain})

    completed_at = Keyword.get(opts, :completed_at, DateTime.utc_now(:microsecond))
    speaker = Keyword.get(opts, :speaker, "Alice")

    actor_event =
      %ActorEvent{}
      |> ActorEvent.changeset(%{
        agent_uid: owner_uid,
        binding_name: "brain-stage-b",
        session_id: key,
        source_event_id: "stage-b-#{Ecto.UUID.generate()}",
        signal_channel_id: brain["channel_id"],
        type: event_type,
        available_at: completed_at,
        queue_sequence: System.unique_integer([:positive]),
        input_state: "open",
        completed_at: completed_at,
        payload: %{
          "data" => %{
            "entry" => %{
              "text" => text,
              "author" => %{"display_name" => speaker}
            }
          }
        }
      })
      |> Repo.insert!()

    response_rows =
      Keyword.get(opts, :response_rows, [
        [
          %{
            "type" => "message",
            "role" => "assistant",
            "content" => [%{"type" => "output_text", "text" => "Task completed."}]
          }
        ]
      ])

    final_response =
      response_rows
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {response_items, index}, previous ->
        row_time = DateTime.add(completed_at, index - length(response_rows), :microsecond)

        %Message{inserted_at: row_time, updated_at: row_time}
        |> Message.changeset(%{
          subject_uid: owner_uid,
          conversation_id: conversation.id,
          type: "message",
          role: "assistant",
          status: "complete",
          content: response_items,
          previous_message_id: previous && previous.id,
          metadata: %{"request_metadata" => %{"actor_event_id" => actor_event.id}}
        })
        |> Repo.insert!()
      end)

    case final_response do
      nil ->
        actor_event

      %Message{id: final_id} ->
        actor_event
        |> ActorEvent.changeset(%{
          final_response_id: "resp_#{final_id}",
          turn_outcome: "loop_finished"
        })
        |> Repo.update!()
    end
  end

  defp unroutable_task_outcome!(owner_uid, key, text) do
    completed_at = DateTime.utc_now(:microsecond)

    %ActorEvent{}
    |> ActorEvent.changeset(%{
      agent_uid: owner_uid,
      binding_name: "brain-stage-b",
      session_id: key,
      source_event_id: "stage-b-unroutable-#{Ecto.UUID.generate()}",
      type: "im.message.addressed",
      available_at: completed_at,
      queue_sequence: System.unique_integer([:positive]),
      input_state: "open",
      completed_at: completed_at,
      payload: %{"data" => %{"entry" => %{"text" => text}}}
    })
    |> Repo.insert!()
  end

  defp visible_signal_material!(owner_uid, text, content_hash, opts \\ []) do
    now = Keyword.get(opts, :observed_at, DateTime.utc_now(:microsecond))
    suffix = Ecto.UUID.generate()
    binding_name = "brain-stage-b-#{suffix}"
    binding_fixture(owner_uid, binding_name, :ignore)

    context =
      AdapterContext.new(
        agent_uid: owner_uid,
        binding_name: binding_name,
        adapter: "lark",
        user_name: "Lark"
      )

    group =
      %Group{}
      |> Group.changeset(%{
        name: "brain-stage-b-#{suffix}",
        display_name: "Brain Stage B",
        domain: :im_group,
        metadata: BindingMembership.project(%{}, context, :joined, now)
      })
      |> Repo.insert!()

    channel =
      %Channel{}
      |> Channel.changeset(%{
        id: "brain:stage-b:#{suffix}",
        kind: :im_group,
        reply_mode: :entry,
        name: "Brain Stage B",
        metadata: %{},
        raw_payload: %{},
        principal_group_id: group.id,
        first_seen_at: now,
        last_seen_at: now
      })
      |> Repo.insert!()

    %SignalEntry{}
    |> SignalEntry.changeset(%{
      signal_channel_id: channel.id,
      source_entry_id: "message-#{suffix}",
      text: text,
      attachments: [],
      links: [],
      author: %{"display_name" => "Alice"},
      mentions: [],
      metadata: %{},
      raw_payload: %{},
      provider_time: now,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: "signal-gateway-entry:#{String.replace(suffix, "-", "_")}",
      content_hash: content_hash,
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!()
  end

  defp visible_dm_signal_material!(owner_uid, peer_uid, text, content_hash, opts \\ []) do
    now = Keyword.get(opts, :observed_at, DateTime.utc_now(:microsecond))
    suffix = Ecto.UUID.generate()
    channel_id = "brain:stage-b:dm:#{suffix}"

    %Channel{}
    |> Channel.changeset(%{
      id: channel_id,
      kind: :im_dm,
      reply_mode: :entry,
      name: "Brain Stage B DM",
      metadata: %{"dm_peer_principal_uid" => peer_uid},
      raw_payload: %{},
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!()

    %ActorEvent{}
    |> ActorEvent.changeset(%{
      agent_uid: owner_uid,
      binding_name: "brain-stage-b-dm",
      session_id: "brain-stage-b-dm-#{suffix}",
      source_event_id: "brain-stage-b-dm-observed-#{suffix}",
      signal_channel_id: channel_id,
      source_entry_id: "message-#{suffix}",
      type: "im.message.observed",
      available_at: now,
      queue_sequence: System.unique_integer([:positive]),
      input_state: "open",
      payload: %{}
    })
    |> Repo.insert!()

    %SignalEntry{}
    |> SignalEntry.changeset(%{
      signal_channel_id: channel_id,
      source_entry_id: "message-#{suffix}",
      text: text,
      attachments: [],
      links: [],
      author: %{"display_name" => "Alice", "principal_uid" => peer_uid},
      mentions: [],
      metadata: %{},
      raw_payload: %{},
      provider_time: now,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: "signal-gateway-entry:#{String.replace(suffix, "-", "_")}",
      content_hash: content_hash,
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!()
  end

  defp external_signal_entry! do
    suffix = Ecto.UUID.generate()
    now = DateTime.utc_now(:microsecond)

    {:ok, external} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.transact(fn repo ->
          channel =
            %Channel{}
            |> Channel.changeset(%{
              id: "brain:stage-b:external:#{suffix}",
              kind: :webhook_endpoint,
              reply_mode: :none,
              name: "Brain Stage B External",
              metadata: %{},
              raw_payload: %{},
              first_seen_at: now,
              last_seen_at: now
            })
            |> repo.insert!()

          entry =
            %SignalEntry{}
            |> SignalEntry.changeset(%{
              signal_channel_id: channel.id,
              source_entry_id: "external-message-#{suffix}",
              text: "source before edit",
              attachments: [],
              links: [],
              author: %{"display_name" => "Alice"},
              mentions: [],
              metadata: %{},
              raw_payload: %{},
              provider_time: now,
              reactions: %{},
              raw_reaction_keys: %{},
              document_id: "signal-gateway-entry:#{String.replace(suffix, "-", "_")}",
              content_hash: "hash-v1",
              ai_message_id: Ecto.UUID.generate(),
              first_seen_at: now,
              last_seen_at: now
            })
            |> repo.insert!()

          {:ok, %{entry: entry, channel: channel}}
        end)
      end)

    external
  end

  defp delete_external_signal_entry!(external) do
    {:ok, :deleted} =
      Sandbox.unboxed_run(Repo, fn ->
        Repo.transact(fn repo ->
          repo.delete_all(
            from entry in SignalEntry, where: entry.document_id == ^external.entry.document_id
          )

          repo.delete_all(from channel in Channel, where: channel.id == ^external.channel.id)
          {:ok, :deleted}
        end)
      end)

    :ok
  end

  defp principal_cursor!(owner_uid) do
    Repo.get_by!(Cursor, scope_kind: :principal, scope_key: owner_uid)
  end

  defp empty_plan, do: %{"operations" => [], "skill_updates" => []}

  defp select_all_locator_response(request) do
    materials = request_payload(request)["material_index"]
    refs = Enum.map(materials, & &1["material_ref"])

    topics =
      case refs do
        [] -> []
        refs -> [%{"query" => "durable material", "material_refs" => refs}]
      end

    response_summary(%{"material_refs" => refs, "topics" => topics})
  end

  defp stage_b_phase(request) do
    case get_in(request.body, ["text", "format", "name"]) do
      "brain_stage_b_locator" ->
        :locator

      "brain_stage_b_curator" ->
        :curator

      _other ->
        system_text =
          request.body["input"]
          |> Enum.find(&(&1["role"] == "system"))
          |> get_in(["content", Access.at(0), "text"])

        if is_binary(system_text) and String.contains?(system_text, "compress the resident memo") do
          :memo
        else
          payload = request_payload(request)
          if Map.has_key?(payload, "material_index"), do: :locator, else: :curator
        end
    end
  end

  defp curator_payload(request) do
    request_payload(request)
  end

  defp request_payload(request) do
    request.body["input"]
    |> Enum.find(&(&1["role"] == "user"))
    |> get_in(["content", Access.at(0), "text"])
    |> Ankole.JSON.decode!()
  end

  defp request_token_cost(request) do
    input_tokens =
      request.body
      |> Map.take(["input", "text"])
      |> Ankole.JSON.encode!()
      |> Ankole.Kernel.estimate_o200k_base_tokens()

    input_tokens + request.body["max_output_tokens"]
  end

  defp receive_budgeted_requests(requests) do
    receive do
      {:budgeted_request, request} -> receive_budgeted_requests([request | requests])
    after
      100 -> Enum.reverse(requests)
    end
  end

  defp receive_store_payloads! do
    assert_receive {:store_curator_payload, first_store, first_payload}, 1_000
    assert_receive {:store_curator_payload, second_store, second_payload}, 1_000
    %{first_store => first_payload, second_store => second_payload}
  end

  defp assert_store_payload_isolation!(payloads, peer_uid) do
    assert Map.keys(payloads) |> MapSet.new() == MapSet.new(["shared", "dm:#{peer_uid}"])

    shared_payload = payloads["shared"]
    private_payload = payloads["dm:#{peer_uid}"]
    refute Enum.any?(shared_payload["materials"], &Map.has_key?(&1, "store_key"))
    refute Enum.any?(private_payload["materials"], &Map.has_key?(&1, "store_key"))
    assert Ankole.JSON.encode!(shared_payload) =~ "SHARED_ONLY_MARKER"
    refute Ankole.JSON.encode!(shared_payload) =~ "PRIVATE_ONLY_MARKER"
    assert Ankole.JSON.encode!(private_payload) =~ "PRIVATE_ONLY_MARKER"
    refute Ankole.JSON.encode!(private_payload) =~ "SHARED_ONLY_MARKER"
    assert private_payload["enabled_skills"] == []
  end

  defp create_knowledge_entry!(scope, actor_uid, name) do
    assert {:ok, %{results: [%{entry_id: entry_id}]}} =
             Knowledge.apply_operations(
               scope,
               %{
                 operation: "create_entry",
                 name: name,
                 type: "topic",
                 summary: "",
                 aliases: [],
                 properties: %{}
               },
               %{kind: :human, uid: actor_uid}
             )

    entry_id
  end

  defp response_summary(plan), do: plan |> Ankole.JSON.encode!() |> response_text()

  defp response_text(text) do
    {:json, 200,
     %{
       "id" => "resp_stage_b_#{System.unique_integer([:positive])}",
       "object" => "response",
       "status" => "completed",
       "output" => [
         %{
           "type" => "message",
           "role" => "assistant",
           "content" => [
             %{"type" => "output_text", "text" => text, "annotations" => []}
           ]
         }
       ],
       "usage" => %{"input_tokens" => 10, "output_tokens" => 10, "total_tokens" => 20}
     }}
  end
end
