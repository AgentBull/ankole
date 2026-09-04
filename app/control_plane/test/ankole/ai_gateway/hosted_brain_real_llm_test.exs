defmodule Ankole.AIGateway.HostedBrainRealLLMTest do
  @moduledoc """
  Real-provider verification of the hosted `brain` tool.

  Run with `ANKOLE_REAL_LLM_E2E=1 mix test --only real_llm`. A real model
  receives the Brain operation catalog as its tools, AIGateway executes the
  calls it makes inside the same Response, and the stored memory changes as a
  result. The tests speak the stateless Responses dialect over SSE.
  """

  use Ankole.AIGatewayCase

  import Ecto.Query

  alias Ankole.Brain.Claims
  alias Ankole.Brain.SchemaPacks
  alias Ankole.Brain.Schemas.Claim

  @moduletag :real_llm
  @moduletag timeout: 300_000

  # The e2e real-LLM suites use this OpenRouter model; OpenAI-hosted models are
  # region-blocked for some keys and answer 403 through OpenRouter.
  @model System.get_env("ANKOLE_REAL_LLM_MODEL", "z-ai/glm-5.3-flash")
  @codename "SILVER-HERON"

  setup do
    api_key = System.get_env("OPEN_ROUTER_API_KEY")

    if api_key in [nil, ""] do
      raise "OPEN_ROUTER_API_KEY is required for real_llm hosted brain tests"
    end

    {:ok, _result} = SchemaPacks.install_packs([])
    %{principal: owner} = human_fixture()
    %{principal: agent} = agent_fixture(%{owner_principal_uid: owner.uid})

    {:ok, _provider} =
      ProviderConfigs.create_provider(%{
        provider_id: "openrouter-real",
        provider_kind: "openrouter",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => api_key}]}
      })

    {:ok, _profile} =
      ModelProfiles.put_model_profile(agent.uid, "primary", %{
        provider_id: "openrouter-real",
        model: @model
      })

    {:ok, %{claim: _seed}} =
      Claims.write_fact(
        %{
          object_slug: "agents/" <> agent.uid,
          claim: "The internal launch codename is #{@codename}.",
          kind: "fact",
          holder: "agents/" <> agent.uid,
          audience_scope: "world",
          notability: "high",
          confidence: 0.95,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "hosted brain real llm seed"
        },
        agent.uid
      )

    %{agent: agent, owner: owner}
  end

  test "an Agent recalls memory through the hosted tool inside one Response", %{agent: agent} do
    {_events, outcome} =
      stream!(
        agent.uid,
        brain_request("primary", """
        Call the recall tool exactly once with the query "internal launch codename".
        Then, without calling any other tool, reply with exactly one line:
        RECALL_OK <the codename from the recall result>
        Do not guess the codename; take it from the recall result.
        """)
      )

    assert outcome.terminal_error == nil

    assert [recall_call] = items_of(outcome, "brain_call")
    assert recall_call["operation"] == "recall"
    assert is_map(recall_call["arguments"])

    assert [recall_output] = items_of(outcome, "brain_output")
    assert recall_output["call_id"] == recall_call["call_id"]
    assert recall_output["status"] == "completed"
    assert Enum.any?(recall_output["output"]["claims"], &(&1["claim"] =~ @codename))

    assert final_text(outcome) =~ @codename
  end

  test "an Agent writes memory through the hosted tool and the claim lands", %{agent: agent} do
    {_events, outcome} =
      stream!(
        agent.uid,
        brain_request("primary", """
        Call the remember tool exactly once to store this fact with kind "fact", scope "world",
        and provenance "release planning note":
        The launch review meeting is on the second Friday of October.
        Then reply with exactly one line: REMEMBER_OK
        """)
      )

    assert outcome.terminal_error == nil

    assert [remember_call] = items_of(outcome, "brain_call")
    assert remember_call["operation"] == "remember"

    assert [remember_output] = items_of(outcome, "brain_output")
    assert remember_output["status"] == "completed"
    assert is_binary(remember_output["output"]["claim_id"])

    claim = Repo.get!(Claim, remember_output["output"]["claim_id"])
    assert claim.claim =~ "launch review"
    assert claim.author_uid == agent.uid
    assert claim.audience_scope == "world"
    assert final_text(outcome) =~ "REMEMBER_OK"
  end

  test "a Human subject without a Turn recalls world knowledge as itself", %{owner: owner} do
    {_events, outcome} =
      stream!(
        owner.uid,
        brain_request("openrouter-real/" <> @model, """
        Call the recall tool exactly once with the query "internal launch codename".
        Then reply with exactly one line: RECALL_OK <the codename from the recall result>
        """)
      )

    assert outcome.terminal_error == nil
    assert [%{"operation" => "recall"}] = items_of(outcome, "brain_call")
    assert [%{"status" => "completed"} = output] = items_of(outcome, "brain_output")
    assert Enum.any?(output["output"]["claims"], &(&1["claim"] =~ @codename))
    assert final_text(outcome) =~ @codename

    # A Human writes into its own principal scope by default.
    {_events, write} =
      stream!(
        owner.uid,
        brain_request("openrouter-real/" <> @model, """
        Call the remember tool exactly once to store this fact with kind "preference" and
        provenance "personal note", without giving a scope:
        I prefer written summaries before any call.
        Then reply with exactly one line: REMEMBER_OK
        """)
      )

    assert write.terminal_error == nil

    assert [%{"status" => "completed", "output" => %{"claim_id" => claim_id}}] =
             items_of(write, "brain_output")

    claim = Repo.get!(Claim, claim_id)
    assert claim.audience_scope == "principal:" <> owner.uid

    assert Repo.exists?(from c in Claim, where: c.id == ^claim_id and c.author_uid == ^owner.uid)
  end

  defp brain_request(model, text) do
    %{
      "model" => model,
      "stream" => true,
      "tools" => [%{"type" => "brain"}],
      "input" => [
        %{
          "type" => "message",
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => text}]
        }
      ]
    }
  end

  defp stream!(subject_uid, request) do
    {:ok, stream, _meta} = AIGateway.open_sse_stream(subject_uid, request)
    collect_events(stream, [])
  end

  # The stream may push its terminal batch and stop without waiting for more
  # demand, so a failed read drains the mailbox before giving up.
  defp collect_events(stream, events) do
    case AIGateway.read_response_stream(stream, 1) do
      :ok -> await_batch(stream, events, 180_000)
      {:error, _reason} -> await_batch(stream, events, 1_000)
    end
  end

  defp await_batch(stream, events, timeout) do
    receive do
      {:ai_gateway_response_stream, _ref, :events, batch, :continue} ->
        collect_events(stream, events ++ batch)

      {:ai_gateway_response_stream, _ref, :events, batch, {:terminal, outcome}} ->
        {events ++ batch, outcome}
    after
      timeout -> raise "real LLM stream ended without a terminal event"
    end
  end

  defp items_of(outcome, type), do: Enum.filter(outcome.public_items, &(&1["type"] == type))

  defp final_text(outcome) do
    outcome.public_items
    |> Enum.filter(&(&1["type"] == "message"))
    |> Enum.flat_map(&(&1["content"] || []))
    |> Enum.map(&(&1["text"] || ""))
    |> Enum.join(" ")
  end
end
