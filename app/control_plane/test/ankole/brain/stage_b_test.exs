defmodule Ankole.Brain.StageBTest do
  use Ankole.AIGatewayCase

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
  alias Ankole.Brain.Config
  alias Ankole.Brain.Dreaming.StageB
  alias Ankole.Brain.Jobs.CuratePrincipal
  alias Ankole.Brain.Jobs.EnqueuePrincipalDreaming
  alias Ankole.Brain.Knowledge
  alias Ankole.Brain.Schemas.Cursor
  alias Ankole.Brain.Scope
  alias Ankole.SignalsGateway.{AdapterContext, BindingMembership, Channel}
  alias Ankole.SignalsGateway.Entry, as: SignalEntry
  alias Ankole.SystemConfig

  @base_time ~U[2026-07-13 00:00:00.000000Z]

  setup do
    :ok = Brain.ensure_registered()
    :ok
  end

  test "mutation failures do not advance the baseline and a new entry can receive a dreaming block" do
    %{principal: agent} = agent_fixture()
    message = conversation_material!(agent.uid, "stage-b-new-entry", "I now prefer vegetables")

    plan = %{
      "store_batches" => [
        %{
          "store_key" => "public",
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
              "body" => "The current preference is vegetarian."
            }
          ]
        }
      ],
      "skill_updates" => []
    }

    configure_model!(agent, fn _request -> response_summary(plan, fenced: true) end)
    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 1})

    assert {:error, :dreaming_mutation_budget_exceeded} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["conversation_message_id"]

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 2})

    assert {:ok,
            %{
              status: :completed,
              material_count: 1,
              operation_count: 2,
              skill_update_count: 0
            }} = StageB.run(agent.uid)

    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == message.id

    {:ok, scope} = Scope.for_store(agent.uid, "public")
    assert {:ok, [entry]} = Knowledge.list_entries(scope, limit: 20)
    assert entry.name == "Diet preference"
    assert {:ok, projection} = Knowledge.open(scope, entry.id, block_limit: :all)

    assert [%{body: "The current preference is vegetarian.", author_kind: :dreaming}] =
             projection.blocks

    assert {:ok, %{status: :no_new_material, material_count: 0}} = StageB.run(agent.uid)
  end

  test "a fully undeclared conversation window advances the cursor instead of pinning it" do
    %{principal: agent} = agent_fixture()

    undeclared =
      for index <- 1..3 do
        undeclared_conversation_material!(
          agent.uid,
          "stage-b-undeclared",
          "external api message #{index}"
        )
      end

    configure_model!(agent, fn _request -> response_summary(empty_plan()) end)
    configure_dreaming!(agent.uid, agent.uid, %{"material_limit" => 3})

    assert {:ok, %{status: :no_new_material, material_count: 0}} = StageB.run(agent.uid)

    skipped = principal_cursor!(agent.uid)
    assert skipped.metadata["conversation_message_id"] == List.last(undeclared).id

    declared = conversation_material!(agent.uid, "stage-b-declared", "durable preference appears")

    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == declared.id
  end

  test "an undeclared conversation window is skipped even when signal material commits" do
    %{principal: agent} = agent_fixture()

    undeclared =
      undeclared_conversation_material!(agent.uid, "stage-b-undeclared-mixed", "external only")

    signal = visible_signal_material!(agent.uid, "durable signal fact", "stage-b-mixed-hash")

    configure_model!(agent, fn _request -> response_summary(empty_plan()) end)
    configure_dreaming!(agent.uid, agent.uid, %{})

    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)

    metadata = principal_cursor!(agent.uid).metadata
    assert metadata["conversation_message_id"] == undeclared.id
    assert metadata["signal_document_id"] == signal.document_id
  end

  test "an invalid curator mutation is retried before the material cursor advances" do
    %{principal: agent} = agent_fixture()
    message = conversation_material!(agent.uid, "stage-b-curator-retry", "durable topic")
    attempts = :atomics.new(1, signed: false)

    configure_model!(agent, fn _request ->
      case :atomics.add_get(attempts, 1, 1) do
        1 ->
          response_summary(%{
            "store_batches" => [
              %{
                "store_key" => "public",
                "operations" => [
                  %{
                    "operation" => "add_relation",
                    "entry_id" => Ecto.UUID.generate(),
                    "predicate" => "depends on",
                    "expected_entry_lock_version" => 1
                  }
                ]
              }
            ],
            "skill_updates" => []
          })

        _retry ->
          response_summary(empty_plan())
      end
    end)

    configure_dreaming!(agent.uid, agent.uid)
    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert :atomics.get(attempts, 1) == 2
    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == message.id
  end

  test "the principal cursor is a cross-node single-flight lease and advances only after commit" do
    %{principal: agent} = agent_fixture()
    message = conversation_material!(agent.uid, "stage-b-single-flight", "one external fact")
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
    refute cursor.metadata["conversation_message_id"]
    assert {:ok, %{status: :already_running}} = StageB.run(agent.uid)

    assert {:snooze, 60} =
             CuratePrincipal.perform(%Oban.Job{args: %{"principal_uid" => agent.uid}})

    send(upstream_pid, :release_curator)
    assert {:ok, %{status: :completed, material_count: 1}} = Task.await(task, 10_000)

    cursor = principal_cursor!(agent.uid)
    assert cursor.metadata["conversation_message_id"] == message.id
    refute cursor.metadata["stage_b_run_id"]
    refute_receive {:curator_waiting, _pid, _request}, 100
  end

  test "token budgeting consumes only a complete material prefix" do
    %{principal: agent} = agent_fixture()

    first =
      conversation_material!(agent.uid, "stage-b-token-budget", "a", inserted_at: @base_time)

    second =
      conversation_material!(agent.uid, "stage-b-token-budget", String.duplicate("long ", 25_000),
        inserted_at: DateTime.add(@base_time, 1, :second)
      )

    configure_model!(agent, fn _request -> response_summary(empty_plan()) end)
    configure_dreaming!(agent.uid, agent.uid, %{"token_limit" => 20_000})

    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == first.id

    assert {:error, :dreaming_token_limit_too_small} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == first.id

    configure_dreaming!(agent.uid, agent.uid, %{"token_limit" => 0})
    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == second.id
  end

  test "locator can skip noise while the cursor consumes the complete scanned batch" do
    %{principal: agent} = agent_fixture()

    first =
      conversation_material!(agent.uid, "stage-b-locator-prefix", "first material",
        inserted_at: @base_time
      )

    second =
      conversation_material!(agent.uid, "stage-b-locator-prefix", "second material",
        inserted_at: DateTime.add(@base_time, 1, :second)
      )

    configure_model!(
      agent,
      fn request ->
        payload = curator_payload(request)
        assert Enum.map(payload["materials"], & &1["message_id"]) == [second.id]
        response_summary(empty_plan())
      end,
      locator: fn request ->
        payload = request_payload(request)
        assert Enum.map(payload["material_index"], & &1["material_id"]) == [first.id, second.id]

        response_summary(%{
          "material_ids" => [second.id],
          "topics" => [%{"query" => "second material", "material_ids" => [second.id]}]
        })
      end
    )

    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :completed, material_count: 2, operation_count: 0}} =
             StageB.run(agent.uid)

    cursor = principal_cursor!(agent.uid)
    assert cursor.metadata["conversation_message_id"] == second.id
    assert {:ok, %{status: :no_new_material}} = StageB.run(agent.uid)
  end

  test "an irrelevant scanned batch advances without calling the curator" do
    %{principal: agent} = agent_fixture()

    first =
      conversation_material!(agent.uid, "stage-b-empty-locator", "routine acknowledgement",
        inserted_at: @base_time
      )

    second =
      conversation_material!(agent.uid, "stage-b-empty-locator", "another acknowledgement",
        inserted_at: DateTime.add(@base_time, 1, :second)
      )

    test_pid = self()

    configure_model!(
      agent,
      fn request ->
        send(test_pid, {:unexpected_curator, request})
        response_summary(empty_plan())
      end,
      locator: fn _request ->
        response_summary(%{"material_ids" => [], "topics" => []})
      end
    )

    configure_dreaming!(agent.uid, agent.uid)

    assert {:ok, %{status: :completed, material_count: 2, operation_count: 0}} =
             StageB.run(agent.uid)

    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == second.id
    refute_receive {:unexpected_curator, _request}, 100
    assert {:ok, %{status: :no_new_material}} = StageB.run(agent.uid)
    assert first.id != second.id
  end

  test "token budget counts locator and curator requests across public and private stores" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()

    public_message =
      conversation_material!(agent.uid, "stage-b-budget-public", "small public material",
        inserted_at: @base_time
      )

    private_message =
      conversation_material!(
        agent.uid,
        "stage-b-budget-private",
        String.duplicate("private ", 25_000),
        inserted_at: DateTime.add(@base_time, 1, :second),
        brain: %{
          "visibility" => "dm",
          "peer_uid" => peer.uid,
          "channel_id" => "dm:stage-b-budget:#{peer.uid}",
          "channel_kind" => "im_dm"
        }
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
    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == public_message.id

    requests = receive_budgeted_requests([])
    assert length(requests) == 2
    assert Enum.sum(Enum.map(requests, &request_token_cost/1)) <= 20_000

    assert {:error, :dreaming_token_limit_too_small} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == public_message.id

    configure_dreaming!(agent.uid, agent.uid, %{"token_limit" => 0})
    assert {:ok, %{status: :completed, material_count: 1}} = StageB.run(agent.uid)
    assert principal_cursor!(agent.uid).metadata["conversation_message_id"] == private_message.id
  end

  test "curator output rejects noncanonical operations and envelopes without advancing" do
    %{principal: agent} = agent_fixture()
    _message = conversation_material!(agent.uid, "stage-b-json-envelope", "external material")
    configure_dreaming!(agent.uid, agent.uid)
    json = Ankole.JSON.encode!(empty_plan())

    invalid_sentinel = %{
      "store_batches" => [
        %{
          "store_key" => "public",
          "operations" => [%{"operation" => "nil", "reason" => "not sure"}]
        }
      ],
      "skill_updates" => []
    }

    configure_model!(agent, fn _request -> response_summary(invalid_sentinel) end)

    assert {:error,
            {:invalid_dreaming_operation,
             %{store_key: "public", index: 0, operation: "nil", fields: fields}}} =
             StageB.run(agent.uid)

    assert fields == ["operation", "reason"]
    refute principal_cursor!(agent.uid).metadata["conversation_message_id"]

    alias_operation = %{
      "store_batches" => [
        %{
          "store_key" => "public",
          "operations" => [
            %{
              "op" => "create_entry",
              "name" => "Compatibility residue",
              "type" => "topic"
            }
          ]
        }
      ],
      "skill_updates" => []
    }

    configure_model!(agent, fn _request -> response_summary(alias_operation) end)

    assert {:error,
            {:invalid_dreaming_operation,
             %{store_key: "public", index: 0, operation: nil, fields: alias_fields}}} =
             StageB.run(agent.uid)

    assert alias_fields == ["name", "op", "type"]
    refute principal_cursor!(agent.uid).metadata["conversation_message_id"]

    configure_model!(agent, fn _request -> response_text("Explanation:\n#{json}") end)
    assert {:error, _invalid_json} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["conversation_message_id"]

    multiple = "```json\n#{json}\n```\n```json\n#{json}\n```"
    configure_model!(agent, fn _request -> response_text(multiple) end)
    assert {:error, _invalid_multiple_payload} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["conversation_message_id"]
  end

  test "source hashes are rechecked under the write transaction after model inference" do
    %{principal: agent} = agent_fixture()
    source = visible_signal_material!(agent.uid, "source before edit", "hash-v1")
    test_pid = self()

    plan = %{
      "store_batches" => [
        %{
          "store_key" => "public",
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
              "body" => "Quoted evidence src:#{source.document_id}"
            }
          ]
        }
      ],
      "skill_updates" => []
    }

    configure_model!(agent, fn request ->
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
      search_text: "source after edit",
      content_hash: "hash-v2"
    )
    |> Repo.update!()

    send(upstream_pid, :release_source_curator)
    assert {:ok, %{status: :completed}} = Task.await(task, 10_000)

    {:ok, scope} = Scope.for_store(agent.uid, "public")
    assert {:ok, [entry]} = Knowledge.list_entries(scope, limit: 20)
    assert {:ok, projection} = Knowledge.open(scope, entry.id, block_limit: :all)
    assert [%{body: body, author_kind: :dreaming}] = projection.blocks
    assert body =~ "原文已变化"
    refute body =~ "src:"
  end

  test "public and private materials are curated in isolated calls with one global mutation budget" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()

    public_message =
      conversation_material!(agent.uid, "stage-b-mixed-public", "PUBLIC_ONLY_MARKER",
        inserted_at: @base_time
      )

    dm_message =
      conversation_material!(agent.uid, "stage-b-mixed-dm", "PRIVATE_ONLY_MARKER",
        inserted_at: DateTime.add(@base_time, 1, :second),
        brain: %{
          "visibility" => "dm",
          "peer_uid" => peer.uid,
          "channel_id" => "dm:stage-b:#{peer.uid}",
          "channel_kind" => "im_dm"
        }
      )

    test_pid = self()

    configure_model!(agent, fn request ->
      payload = curator_payload(request)
      [store_key] = payload["materials"] |> Enum.map(& &1["store_key"]) |> Enum.uniq()
      send(test_pid, {:store_curator_payload, store_key, payload})

      name = if store_key == "public", do: "Public topic", else: "Private topic"

      response_summary(%{
        "store_batches" => [
          %{
            "store_key" => store_key,
            "operations" => [
              %{
                "operation" => "create_entry",
                "name" => name,
                "type" => "topic",
                "summary" => "",
                "aliases" => [],
                "properties" => %{}
              }
            ]
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
    refute cursor.metadata["conversation_message_id"]
    {:ok, all_scope} = Scope.for_console(agent.uid, :all)
    assert {:ok, []} = Knowledge.list_entries(all_scope, limit: 20)

    configure_dreaming!(agent.uid, agent.uid, %{"mutation_limit" => 2})

    assert {:ok, %{status: :completed, material_count: 2, operation_count: 2, run_id: run_id}} =
             StageB.run(agent.uid)

    second_payloads = receive_store_payloads!()
    assert_store_payload_isolation!(second_payloads, peer.uid)

    cursor = principal_cursor!(agent.uid)
    assert cursor.metadata["conversation_message_id"] == dm_message.id
    refute cursor.metadata["conversation_message_id"] == public_message.id

    assert {:ok, entries} = Knowledge.list_entries(all_scope, limit: 20)

    assert MapSet.new(Enum.map(entries, &{&1.store_key, &1.name})) ==
             MapSet.new([{"public", "Public topic"}, {"dm:#{peer.uid}", "Private topic"}])

    traces =
      AIGatewayConversation
      |> where([conversation], like(conversation.conversation_key, ^"brain.dreaming:#{run_id}:%"))
      |> Repo.all()

    assert length(traces) == 2

    assert traces
           |> Map.new(&{&1.metadata["brain"]["visibility"], &1.metadata["brain"]})
           |> then(fn by_visibility ->
             by_visibility["public"] == %{"visibility" => "public"} and
               by_visibility["dm"]["peer_uid"] == peer.uid and
               by_visibility["dm"]["channel_kind"] == "im_dm"
           end)
  end

  test "private dreaming calls cannot mutate the global skill overlay" do
    %{principal: agent} = agent_fixture()
    %{principal: peer} = human_fixture()

    _message =
      conversation_material!(agent.uid, "stage-b-private-skill", "private correction",
        brain: %{
          "visibility" => "dm",
          "peer_uid" => peer.uid,
          "channel_id" => "dm:stage-b:#{peer.uid}",
          "channel_kind" => "im_dm"
        }
      )

    test_pid = self()

    configure_model!(agent, fn request ->
      payload = curator_payload(request)
      send(test_pid, {:private_skill_payload, payload})

      response_summary(%{
        "store_batches" => [],
        "skill_updates" => [
          %{"skill_name" => "research", "mode" => "append", "content" => "secret lesson"}
        ]
      })
    end)

    configure_dreaming!(agent.uid, agent.uid)
    assert {:error, :private_skill_updates_forbidden} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["conversation_message_id"]

    assert_receive {:private_skill_payload, payload}, 1_000
    assert payload["enabled_skills"] == []
    assert Enum.map(payload["materials"], & &1["store_key"]) == ["dm:#{peer.uid}"]
  end

  test "curator receives authoritative maintenance and learning policy" do
    %{principal: agent} = agent_fixture()
    _message = conversation_material!(agent.uid, "stage-b-policy", "corrected workflow lesson")
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

    assert get_in(payload, ["curation_policy", "induction", "minimum_evidence_count"]) == 2

    assert get_in(payload, ["curation_policy", "skill_updates", "overlap_revision_threshold"]) ==
             0.6

    assert get_in(payload, ["curation_policy", "skill_updates", "required_shape"]) ==
             "situation -> caution"

    assert get_in(payload, ["curation_policy", "task_lessons", "triggers"]) ==
             ["error_recovery", "human_correction", "non_obvious_multistep_success"]

    assert get_in(payload, ["curation_policy", "entry_maintenance", "recheck_after_body_edit"]) ==
             ["summary", "aliases"]
  end

  test "overlapping skill append requires replace and does not consume material" do
    %{principal: agent} = agent_fixture()
    message = conversation_material!(agent.uid, "stage-b-overlap", "repeated PDF lesson")
    existing = "Large PDF review -> verify each rendered page before delivery."

    assert {:ok, overlay} = Library.skill_append(agent.uid, "nano-pdf", existing)

    plan = %{
      "store_batches" => [],
      "skill_updates" => [
        %{"skill_name" => "nano-pdf", "mode" => "append", "content" => existing}
      ]
    }

    configure_model!(agent, fn _request -> response_summary(plan) end)
    configure_dreaming!(agent.uid, agent.uid)

    assert {:error, :dreaming_skill_append_requires_replace} = StageB.run(agent.uid)
    refute principal_cursor!(agent.uid).metadata["conversation_message_id"] == message.id

    assert {:ok, current} = Library.skill_overlay(agent.uid, "nano-pdf")
    assert current.id == overlay.id
    assert current.overlay_json == %{"text" => existing}
  end

  test "skill append conflicts with a concurrent overlay change and does not consume material" do
    %{principal: agent} = agent_fixture()
    message = conversation_material!(agent.uid, "stage-b-skill-cas", "new PDF lesson")
    assert {:ok, _overlay} = Library.skill_append(agent.uid, "nano-pdf", "Existing guidance.")
    test_pid = self()

    plan = %{
      "store_batches" => [],
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
    refute principal_cursor!(agent.uid).metadata["conversation_message_id"] == message.id

    assert {:ok, current} = Library.skill_overlay(agent.uid, "nano-pdf")
    assert current.overlay_json["text"] =~ "Concurrent operator guidance."
    refute current.overlay_json["text"] =~ "Scanned PDF"
  end

  test "locator topics retrieve an old relevant entry instead of the latest directory slice" do
    %{principal: agent} = agent_fixture()
    _message = conversation_material!(agent.uid, "stage-b-relevant-knowledge", "verdant quokka")
    {:ok, scope} = Scope.for_store(agent.uid, "public")

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
          "material_ids" => [material["material_id"]],
          "topics" => [
            %{
              "query" => "Verdant quokka dossier",
              "material_ids" => [material["material_id"]]
            }
          ]
        })
      end
    )

    configure_dreaming!(agent.uid, agent.uid)
    assert {:ok, %{status: :completed}} = StageB.run(agent.uid)
    assert_receive {:knowledge_payload, payload}, 1_000

    assert Enum.any?(payload["current_knowledge"], fn context ->
             get_in(context, ["entry", "id"]) == relevant_id
           end)
  end

  test "curator operations use the exact projection fence supplied by the server" do
    %{principal: agent} = agent_fixture()

    _message =
      conversation_material!(agent.uid, "stage-b-projection-fence", "verdant quokka update")

    {:ok, scope} = Scope.for_store(agent.uid, "public")
    entry_id = create_knowledge_entry!(scope, agent.uid, "Verdant quokka dossier")

    configure_model!(
      agent,
      fn _request ->
        response_summary(%{
          "store_batches" => [
            %{
              "store_key" => "public",
              "operations" => [
                %{
                  "operation" => "set_summary",
                  "entry_id" => entry_id,
                  "summary" => "Current verdant quokka evidence"
                }
              ]
            }
          ],
          "skill_updates" => []
        })
      end,
      locator: fn request ->
        [material] = request_payload(request)["material_index"]

        response_summary(%{
          "material_ids" => [material["material_id"]],
          "topics" => [
            %{
              "query" => "Verdant quokka dossier",
              "material_ids" => [material["material_id"]]
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

  test "the minute poll schedules each enabled principal once per local date" do
    %{principal: agent} = agent_fixture()
    _human = human_fixture()

    on_exit(fn -> AppConfigure.delete_global(SystemConfig.timezone_definition()) end)
    assert {:ok, _timezone} = SystemConfig.put_timezone("Asia/Singapore")
    configure_dreaming!(agent.uid, agent.uid, %{"schedule_local_time" => "04:30"})

    before = %Oban.Job{args: %{"now" => "2026-07-13T20:29:00Z"}}
    due = %Oban.Job{args: %{"now" => "2026-07-13T20:30:00Z"}}
    next_day = %Oban.Job{args: %{"now" => "2026-07-14T20:30:00Z"}}

    assert :ok = EnqueuePrincipalDreaming.perform(before)
    assert [] = all_enqueued(worker: CuratePrincipal)

    assert :ok = EnqueuePrincipalDreaming.perform(due)
    assert :ok = EnqueuePrincipalDreaming.perform(due)

    assert [%Oban.Job{args: first_args}] = all_enqueued(worker: CuratePrincipal)
    assert first_args["principal_uid"] == agent.uid
    assert first_args["local_date"] == "2026-07-14"
    assert first_args["timezone"] == "Asia/Singapore"

    assert :ok = EnqueuePrincipalDreaming.perform(next_day)

    assert [first, second] =
             all_enqueued(worker: CuratePrincipal)
             |> Enum.sort_by(& &1.args["local_date"])

    assert first.args["local_date"] == "2026-07-14"
    assert second.args["local_date"] == "2026-07-15"
  end

  defp configure_model!(agent, curator_fun, opts \\ []) do
    locator_fun = Keyword.get(opts, :locator, &select_all_locator_response/1)

    base_url =
      start_upstream_server(fn request ->
        case stage_b_phase(request) do
          :locator -> locator_fun.(request)
          :curator -> curator_fun.(request)
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
             ModelProfiles.put_model_profile(agent.uid, "heavy", %{
               provider_id: provider_id,
               model: "gpt-stage-b-test"
             })
  end

  defp configure_dreaming!(owner_uid, model_uid, overrides \\ %{}) do
    assert {:ok, config} = Config.dreaming(owner_uid)

    config =
      config
      |> Map.merge(%{"enabled" => true, "model_agent_uid" => model_uid})
      |> Map.merge(overrides)

    assert {:ok, _config} =
             AppConfigure.put_for_agent(owner_uid, Config.dreaming_definition(), config)
  end

  defp conversation_material!(owner_uid, key, text, opts \\ []) do
    brain = Keyword.get(opts, :brain, %{"visibility" => "public"})

    {:ok, conversation} =
      Conversations.ensure_conversation(owner_uid, key, metadata: %{"brain" => brain})

    inserted_at = Keyword.get(opts, :inserted_at)

    %Message{inserted_at: inserted_at, updated_at: inserted_at}
    |> Message.changeset(%{
      subject_uid: owner_uid,
      conversation_id: conversation.id,
      type: "message",
      role: "user",
      status: "complete",
      content: [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => text}]
        }
      ],
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp undeclared_conversation_material!(owner_uid, key, text) do
    {:ok, conversation} = Conversations.ensure_conversation(owner_uid, key, metadata: %{})

    %Message{}
    |> Message.changeset(%{
      subject_uid: owner_uid,
      conversation_id: conversation.id,
      type: "message",
      role: "user",
      status: "complete",
      content: [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => text}]
        }
      ],
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp visible_signal_material!(owner_uid, text, content_hash) do
    now = DateTime.utc_now(:microsecond)
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
      formatted_content: %{},
      attachments: [],
      links: [],
      author: %{"display_name" => "Alice"},
      mentions: [],
      metadata: %{},
      raw_payload: %{},
      provider_time: now,
      fallback_visible_text: text,
      reactions: %{},
      raw_reaction_keys: %{},
      document_id: "signal-gateway-entry:#{String.replace(suffix, "-", "_")}",
      search_text: text,
      metadata_text: "",
      content_hash: content_hash,
      first_seen_at: now,
      last_seen_at: now
    })
    |> Repo.insert!()
  end

  defp principal_cursor!(owner_uid) do
    Repo.get_by!(Cursor, scope_kind: :principal, scope_key: owner_uid)
  end

  defp empty_plan, do: %{"store_batches" => [], "skill_updates" => []}

  defp select_all_locator_response(request) do
    materials = request_payload(request)["material_index"]
    ids = Enum.map(materials, & &1["material_id"])

    topics =
      case ids do
        [] -> []
        ids -> [%{"query" => "durable material", "material_ids" => ids}]
      end

    response_summary(%{"material_ids" => ids, "topics" => topics})
  end

  defp stage_b_phase(request) do
    system =
      request.body["input"]
      |> Enum.find(&(&1["role"] == "system"))
      |> get_in(["content", Access.at(0), "text"])

    if system =~ "stage B locator", do: :locator, else: :curator
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
      request.body["input"]
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
    assert Map.keys(payloads) |> MapSet.new() == MapSet.new(["public", "dm:#{peer_uid}"])

    public_payload = payloads["public"]
    private_payload = payloads["dm:#{peer_uid}"]
    assert Enum.map(public_payload["materials"], & &1["store_key"]) == ["public"]
    assert Enum.map(private_payload["materials"], & &1["store_key"]) == ["dm:#{peer_uid}"]
    assert Ankole.JSON.encode!(public_payload) =~ "PUBLIC_ONLY_MARKER"
    refute Ankole.JSON.encode!(public_payload) =~ "PRIVATE_ONLY_MARKER"
    assert Ankole.JSON.encode!(private_payload) =~ "PRIVATE_ONLY_MARKER"
    refute Ankole.JSON.encode!(private_payload) =~ "PUBLIC_ONLY_MARKER"
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

  defp response_summary(plan, opts \\ []) do
    text = Ankole.JSON.encode!(plan)
    text = if Keyword.get(opts, :fenced, false), do: "```json\n#{text}\n```", else: text
    response_text(text)
  end

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
