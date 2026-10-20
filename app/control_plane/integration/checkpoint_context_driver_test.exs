defmodule Ankole.Sessions.CheckpointContextDriverTest do
  alias Ankole.AIGateway.ResponseChain
  alias Ankole.AIGateway.CompactionPolicy
  use Ankole.DataCase, async: false
  @moduletag sandbox: false
  import Ankole.PrincipalsFixtures, only: [agent_fixture: 0]
  import Ankole.AIGatewayCase, only: [start_upstream_server: 1, openai_response_stream_events: 3]
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.Schemas.CompactionArtifact
  alias Ankole.AIGateway.Schemas.Message
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Links
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.SessionsCase, as: RuntimeCase

  test "the real Driver journals tools, recovers sealed replay, and continues through consecutive checkpoints" do
    drivers = RuntimeCase.driver_pids()
    %{principal: agent} = agent_fixture()
    {:ok, _} = SchemaPacks.install_packs([])

    {:ok, _} =
      Objects.create_object(
        %{slug: "concepts/wire-format", type: "concept", title: "Wire Format"},
        agent.uid
      )

    {:ok, _} = Links.add_alias("concepts/wire-format", "Wire Format")

    {:ok, _} =
      Claims.write_fact(
        %{
          object_slug: "concepts/wire-format",
          claim: "DRIVER_TASK_MEMORY",
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

    recorded = start_supervised!({Agent, fn -> %{main: [], light: []} end})
    owner = self()

    url =
      start_upstream_server(fn request ->
        if request.body["model"] == "gpt-compact-light" do
          Agent.update(recorded, &Map.update!(&1, :light, fn xs -> xs ++ [request.body] end))

          {:sse, 200,
           openai_response_stream_events(
             "resp_driver_summary",
             "gpt-compact-light",
             "## Active Task\nComplete the Wire Format task."
           )}
        else
          attempt =
            Agent.get_and_update(recorded, fn state ->
              main = state.main ++ [request.body]
              {length(main), %{state | main: main}}
            end)

          case attempt do
            1 ->
              {:sse, 200, tool_events(request, 1, 100, true)}

            2 ->
              {:json, 400,
               %{
                 "error" => %{
                   "type" => "invalid_request_error",
                   "param" => "input",
                   "message" => "Historical sealed item rejected"
                 }
               }}

            3 ->
              {:sse, 200, tool_events(request, 2, 160_000, false)}

            4 ->
              {:sse, 200, tool_events(request, 3, 100, false)}

            5 ->
              send(owner, :final_request)

              {:sse, 200,
               openai_response_stream_events(
                 "resp_driver_done",
                 "gpt-main",
                 "The Wire Format task is complete."
               )}

            _ ->
              flunk("unexpected model request #{attempt}")
          end
        end
      end)

    provider_id = "checkpoint-driver-#{Ecto.UUID.generate()}"

    {:ok, _} =
      ProviderConfigs.create_provider(%{
        provider_id: provider_id,
        provider_kind: "openai",
        base_url: "#{url}/v1",
        credential_pool: %{"entries" => [%{"label" => "Fixture", "api_key" => "sk-fixture"}]},
        connection_options: %{"transport" => %{}}
      })

    for {profile, model} <- [{"primary", "gpt-main"}, {"light", "gpt-compact-light"}] do
      {:ok, _} =
        ModelProfiles.put_model_profile(agent.uid, profile, %{
          provider_id: provider_id,
          model: model
        })
    end

    {:ok, _} =
      Ankole.AppConfigure.put_global(
        Ankole.AIGateway.CompactionPolicy.config_definition(),
        Map.merge(CompactionPolicy.config(), %{
          "threshold" => 0.5,
          "max_threshold_tokens" => 100_000,
          "tail_rows" => 1
        })
      )

    on_exit(
      Repo.bind_tenant(fn ->
        RuntimeCase.stop_new_drivers(drivers)
        Ankole.AppConfigure.delete_global(Ankole.AIGateway.CompactionPolicy.config_definition())

        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'agent_uid'", j.args) == ^agent.uid)
        )

        Ankole.AgentWorkers.WorkerEnv.delete_agent_rows_in_tx(Repo, agent.uid)
        Ankole.PrincipalsFixtures.delete_agent_fixture_rows(agent.uid)
        ProviderConfigs.delete_provider(provider_id)
      end)
    )

    key = %{agent_uid: agent.uid, session_id: "checkpoint-driver:#{Ecto.UUID.generate()}"}

    {:ok, event} =
      Ankole.Signals.accept(%{
        producer: :kernel,
        target: key,
        sender: agent.uid,
        authorization: Ankole.Principals.WorkAccess.service(),
        source: "test://checkpoint-driver",
        reply_route: %{binding_name: "control-plane:test"},
        id: Ecto.UUID.generate(),
        type: "conversation.message.addressed",
        available_at: DateTime.utc_now(:microsecond),
        data: %{"entry" => %{"text" => "Complete the Wire Format task"}}
      })

    assert_receive :final_request, 20000
    completed = await_completion(event.id)
    assert completed.turn_outcome == "loop_finished"

    %{main: [opening, rejected, recovered, compacted, final], light: summaries} =
      Agent.get(recorded, & &1)

    assert length(summaries) == 2
    assert Ankole.JSON.encode!(rejected) =~ "DRIVER_OLD_SEALED_STATE"

    for request <- [recovered, compacted, final] do
      refute Ankole.JSON.encode!(request) =~ "DRIVER_OLD_SEALED_STATE"
    end

    for request <- [opening, rejected, recovered, compacted, final] do
      assert Enum.count(request["input"], &(Ankole.JSON.encode!(&1) =~ "DRIVER_TASK_MEMORY")) == 1
      refute Map.has_key?(request, "metadata")
      refute Map.has_key?(request, "model_profile")
    end

    for summary <- summaries do
      refute Ankole.JSON.encode!(summary) =~ "DRIVER_TASK_MEMORY"
    end

    conversation_id =
      Repo.one(
        from(message in Message,
          where:
            message.subject_uid == ^agent.uid and
              fragment("?->'request_metadata'->>'signal_id'", message.metadata) == ^event.id,
          select: message.conversation_id,
          distinct: true
        )
      )

    history = ResponseChain.expand_history(conversation_id, stop_at_checkpoint: false)

    requests =
      Enum.filter(history, fn row ->
        row.type == "message" and is_map(row.metadata["request_metadata"]) and
          row.metadata["tool_result_journal"] != true
      end)

    assert requests != []

    for request <- requests do
      assert request.metadata["request_metadata"]["signal_id"] == event.id

      assert request.metadata["model_profile"] == "primary",
             inspect(
               {request.id, request.type,
                Map.take(request.metadata, ~w(model_profile request_model request_item_count))}
             )

      assert is_integer(request.metadata["request_item_count"])
      originals = Enum.take(request.content, request.metadata["request_item_count"])
      refute Ankole.JSON.encode!(originals) =~ "DRIVER_TASK_MEMORY"
    end

    checkpoints = Enum.filter(history, &(&1.type == "checkpoint"))
    assert length(checkpoints) == 2

    for checkpoint <- checkpoints do
      artifact = Repo.get!(CompactionArtifact, checkpoint.id)
      assert Ankole.JSON.encode!(artifact.content["brain_context_pack"]) =~ "DRIVER_TASK_MEMORY"
    end

    journals = Enum.filter(history, &(&1.metadata["tool_result_journal"] == true))
    assert length(journals) == 3

    for {journal, index} <- Enum.with_index(journals, 1) do
      assert [%{"call_id" => call_id, "output" => output}] = journal.content
      assert call_id == "driver-todo-#{index}"

      assert Ankole.JSON.decode!(output)["todos"] == [
               %{
                 "id" => "wire",
                 "content" => "Complete the Wire Format task",
                 "status" => "completed"
               }
             ]
    end

    assert List.last(final["input"])["type"] == "function_call_output"

    refute Repo.exists?(
             from(message in Message,
               where: message.subject_uid == ^agent.uid and message.status == "generating"
             )
           )
  end

  defp tool_events(request, round, tokens, sealed?) do
    call = %{
      "id" => "fc_driver_#{round}",
      "type" => "function_call",
      "call_id" => "driver-todo-#{round}",
      "name" => "todo",
      "arguments" =>
        Ankole.JSON.encode!(%{
          "todos" => [
            %{
              "id" => "wire",
              "content" => "Complete the Wire Format task",
              "status" => "completed"
            }
          ]
        }),
      "status" => "completed"
    }

    output =
      if sealed? do
        [
          %{
            "type" => "reasoning",
            "id" => "rs_driver",
            "summary" => [],
            "encrypted_content" => "DRIVER_OLD_SEALED_STATE"
          },
          call
        ]
      else
        [call]
      end

    response = %{
      "id" => "resp_driver_#{round}",
      "object" => "response",
      "status" => "in_progress",
      "model" => request.body["model"],
      "output" => [],
      "usage" => %{}
    }

    [
      %{"type" => "response.created", "sequence_number" => 0, "response" => response},
      %{
        "type" => "response.output_item.added",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => %{call | "arguments" => "", "status" => "in_progress"}
      },
      %{
        "type" => "response.output_item.done",
        "sequence_number" => 2,
        "output_index" => 0,
        "item" => call
      },
      %{
        "type" => "response.completed",
        "sequence_number" => 3,
        "response" => %{
          response
          | "status" => "completed",
            "output" => output,
            "usage" => %{
              "input_tokens" => tokens - 1,
              "output_tokens" => 1,
              "total_tokens" => tokens
            }
        }
      }
    ]
  end

  defp await_completion(id, attempts \\ 200)

  defp await_completion(id, 0) do
    flunk("Driver input did not complete: #{inspect(Repo.get!(Signal, id))}")
  end

  defp await_completion(id, attempts) do
    case Repo.get!(Signal, id) do
      %Signal{completed_at: %DateTime{}} = event ->
        event

      %Signal{input_state: "dead_letter"} = event ->
        flunk("Driver input failed: #{inspect(event)}")

      _ ->
        receive do
        after
          25 -> await_completion(id, attempts - 1)
        end
    end
  end
end
