defmodule Ankole.Sessions.Tools.BrainTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.Library
  alias Ankole.Brain.Claims
  alias Ankole.Brain.LibraryKnowledge
  alias Ankole.Brain.Objects
  alias Ankole.Brain.SchemaPacks
  alias Ankole.RuntimeFabric.V1.ReadToolRequest
  alias Ankole.Sessions.JobTurnRef
  alias Ankole.Sessions.ReadToolBroker
  alias Ankole.Sessions.Tools

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

    %{agent: agent, object: object, turn: job_turn(agent.uid)}
  end

  test "declares the hosted read subset as read-only Job tools" do
    declarations = Tools.Brain.declarations()

    assert Enum.map(declarations, & &1["name"]) == ["recall", "get_page"]

    assert Enum.map(declarations, &Map.take(&1, ~w(type name description parameters))) ==
             Ankole.Brain.Tools.function_specs(Tools.Brain.operations())

    for declaration <- declarations do
      assert declaration["read_only"] == true
      assert declaration["destructive"] == false
      assert declaration["execution_mode"] == "parallel"
    end
  end

  test "recall runs for the Job's Agent through the read-tool broker", context do
    request = request("recall", %{"query" => "wire format dated facts"})

    assert {:ok, result} = ReadToolBroker.handle_read(context.turn, request, %{request_id: "r"})
    assert [claim | _rest] = result["details"]["claims"]
    assert claim["claim"] == "The wire format carries dated facts"
    assert Ankole.JSON.decode!(result["output"]) == result["details"]
    refute result["is_error"]
  end

  test "get_page renders the page and prefixes the hint for a Skill discovery record",
       context do
    assert {:ok, result} =
             ReadToolBroker.handle_read(
               context.turn,
               request("get_page", %{"reference" => context.object.slug}),
               %{request_id: "r"}
             )

    assert result["details"]["page"]["slug"] == context.object.slug
    assert String.starts_with?(result["output"], "{")

    # The Agent sees the discovery records of its enabled recall-only Skills,
    # which the shipped library provides.
    assert {:ok, sources} = Library.shipped_skill_sources([])
    recall_only = Enum.filter(sources, &(&1.metadata["brain_recall_only"] == true))

    assert {:ok, _report} =
             LibraryKnowledge.sync(
               sets: [
                 %{
                   kind: :lazy_skills,
                   set_id: "job-read-lazy",
                   name: "Job read lazy",
                   skills: recall_only
                 }
               ]
             )

    assert {:ok, _sync} = Library.sync_agent_skills(context.agent.uid)

    assert {:ok, %{slugs: [lazy_slug | _rest]}} =
             Ankole.Brain.LazySkillVisibility.for_querier(context.agent.uid)

    assert {:ok, lazy} = Tools.Brain.read(context.turn, "get_page", %{"reference" => lazy_slug})
    assert String.starts_with?(lazy.output, Ankole.Brain.Tools.lazy_skill_hint())
    assert lazy.details["page"]["slug"] == lazy_slug
  end

  test "a write operation and invalid arguments do not reach Brain", context do
    assert {:error, error} =
             ReadToolBroker.handle_read(
               context.turn,
               request("remember", %{"claim" => "x", "provenance" => "test"}),
               %{request_id: "r"}
             )

    assert error["code"] == "unknown_read_tool"

    assert {:error, {:unknown_operation, "remember"}} =
             Tools.Brain.read(context.turn, "remember", %{})

    assert {:error, error} =
             ReadToolBroker.handle_read(
               context.turn,
               request("recall", %{"query" => "wire", "budget_tokens" => 0}),
               %{request_id: "r"}
             )

    assert error["code"] == "read_tool_failed"
    assert error["message"] =~ "budget_tokens"
  end

  test "a Signal that another Agent owns refuses the read", context do
    %{principal: other} = agent_fixture()
    foreign = job_turn(other.uid)
    turn = %JobTurnRef{context.turn | signal_id: foreign.signal_id}

    assert {:error, :signal_not_owned} =
             Tools.Brain.read(turn, "recall", %{"query" => "wire format"})

    assert {:error, error} =
             ReadToolBroker.handle_read(turn, request("recall", %{"query" => "wire format"}), %{
               request_id: "r"
             })

    assert error["code"] == "signal_not_owned"
  end

  defp job_turn(agent_uid) do
    signal =
      Ankole.AIGateway.ResponseFixtures.signal_fixture(agent_uid, "job:1000", "job-turn")

    %JobTurnRef{
      agent_uid: agent_uid,
      session_id: "job:1000",
      signal_id: signal.id,
      job_id: 1000,
      attempt: 1
    }
  end

  defp request(name, args),
    do: struct!(ReadToolRequest, name: name, arguments_json: Ankole.JSON.encode!(args))
end
