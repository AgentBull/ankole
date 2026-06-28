defmodule Ankole.AIGatewayCase do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ankole.AIAgent.Schemas.Conversation
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.ActorRuntime.Schemas.ActorSessionActivation
  alias Ankole.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.Repo

  using do
    quote do
      use Ankole.DataCase, async: false

      import Ankole.AIGatewayCase
      import Ankole.PrincipalsFixtures

      alias Ankole.AIGateway, warn: false
      alias Ankole.AIGateway.ProviderConfigs, warn: false
      alias Ankole.AIAgent.ModelProfiles, warn: false
      alias Ankole.ActorRuntime.RPCLane, warn: false
      alias AnkoleWeb.AIGatewayTokens, warn: false
    end
  end

  @doc false
  def chat_completion_body(model, content) do
    %{
      "id" => "chatcmpl_#{System.unique_integer([:positive])}",
      "object" => "chat.completion",
      "created" => 1_764_967_971,
      "model" => model,
      "choices" => [
        %{
          "index" => 0,
          "message" => %{"role" => "assistant", "content" => content},
          "finish_reason" => "stop"
        }
      ],
      "usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2, "total_tokens" => 5}
    }
  end

  @doc false
  def stream_sse_messages(events, state, handler) do
    Enum.reduce_while(events, {:ok, state}, fn event, {:ok, state} ->
      case handler.("data: #{Ankole.JSON.encode!(event)}\n\n", state) do
        {:cont, state} -> {:cont, {:ok, state}}
        {:halt, {:error, reason}} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc false
  def anthropic_stream_events do
    [
      %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_anthropic",
          "type" => "message",
          "role" => "assistant",
          "model" => "claude-sonnet-4-5",
          "content" => [],
          "usage" => %{"input_tokens" => 3, "output_tokens" => 0}
        }
      },
      %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text", "text" => ""}
      },
      %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "hello claude"}
      },
      %{"type" => "content_block_stop", "index" => 0},
      %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{"output_tokens" => 2}
      },
      %{"type" => "message_stop"}
    ]
  end

  @doc false
  def openai_response_stream_events(response_id, model, text) do
    response =
      %{
        "id" => response_id,
        "object" => "response",
        "created_at" => 1_764_967_971,
        "completed_at" => nil,
        "status" => "in_progress",
        "model" => model,
        "previous_response_id" => nil,
        "output" => [],
        "usage" => %{}
      }

    item = %{
      "id" => "msg_azure_v1",
      "type" => "message",
      "status" => "completed",
      "role" => "assistant",
      "content" => [%{"type" => "output_text", "text" => text, "annotations" => []}]
    }

    [
      %{"type" => "response.created", "sequence_number" => 0, "response" => response},
      %{
        "type" => "response.output_item.added",
        "sequence_number" => 1,
        "output_index" => 0,
        "item" => %{item | "status" => "in_progress", "content" => []}
      },
      %{
        "type" => "response.output_text.delta",
        "sequence_number" => 2,
        "item_id" => item["id"],
        "output_index" => 0,
        "content_index" => 0,
        "delta" => text
      },
      %{
        "type" => "response.completed",
        "sequence_number" => 3,
        "response" => %{
          response
          | "completed_at" => 1_764_967_972,
            "status" => "completed",
            "output" => [item]
        }
      }
    ]
  end

  @doc false
  def assign_worker_route(agent_uid, session_id) do
    route = "route-#{System.unique_integer([:positive])}"
    worker_id = "worker-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(%AgentComputerWorker{
      worker_id: worker_id,
      status: "ready",
      version: "test",
      capacity: %{},
      load: %{},
      transport_route: route,
      last_worker_heartbeat_at: now,
      started_at: now,
      metadata: %{"runtime" => "test"}
    })

    Repo.insert!(%ActorSessionWorkerAssignment{
      agent_uid: agent_uid,
      session_id: session_id,
      worker_id: worker_id,
      transport_route: route,
      status: "assigned",
      assigned_at: now,
      metadata: %{}
    })

    conversation =
      Repo.insert!(%Conversation{
        id: Ecto.UUID.generate(),
        agent_uid: agent_uid,
        conversation_key: session_id,
        generation: %{},
        metadata: %{},
        inserted_at: now,
        updated_at: now
      })

    llm_turn =
      Repo.insert!(%LlmTurn{
        id: Ecto.UUID.generate(),
        agent_uid: agent_uid,
        conversation_id: conversation.id,
        kind: "generation",
        status: "started",
        profile: "primary",
        provider: "test-provider",
        model: "z-ai/glm-5.2",
        input_message_ids: [],
        request_context: %{},
        request_refs: [],
        request_patches: [],
        response: %{},
        tool_results: [],
        usage: %{},
        provider_metadata: %{},
        started_at: now,
        inserted_at: now,
        updated_at: now
      })

    activation_uid = "activation-#{System.unique_integer([:positive])}"

    Repo.insert!(%ActorSessionActivation{
      activation_uid: activation_uid,
      agent_uid: agent_uid,
      session_id: session_id,
      actor_epoch: 1,
      status: "active",
      controller_node: "test",
      lease_id: "lease-#{System.unique_integer([:positive])}",
      lease_expires_at: DateTime.add(now, 60, :second),
      assigned_worker_id: worker_id,
      current_llm_turn_id: llm_turn.id,
      revision: 0,
      started_at: now,
      metadata: %{},
      inserted_at: now,
      updated_at: now
    })

    {route,
     %{
       "actor" => %{"agent_uid" => agent_uid, "session_id" => session_id},
       "activation_uid" => activation_uid,
       "actor_epoch" => 1,
       "llm_turn_id" => llm_turn.id,
       "revision" => 0
     }}
  end
end
