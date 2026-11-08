defmodule Ankole.Sessions.Tools.BrainTest do
  use Ankole.DataCase, async: true

  import Ankole.PrincipalsFixtures

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
      Repo.transact(fn ->
        Ankole.Brain.Objects.create_object_in_tx(
          %{
            slug: "concepts/wire-format",
            type: "concept",
            title: "Wire Format",
            body: "Notes about the wire format."
          },
          :system
        )
      end)

    {:ok, %{claim: _fact}} =
      Ankole.Brain.write_fact(
        %{
          subject_page_id: object.id,
          claim: "The wire format carries dated facts",
          kind: "fact",
          holder: "world",
          source_node_id: object.id,
          notability: "medium",
          confidence: 0.9,
          valid_from: DateTime.utc_now(:microsecond),
          provenance: "test"
        },
        agent.uid
      )

    {:ok, _alias} = Ankole.Brain.Links.add_alias(object.id, "Wire Format")

    %{agent: agent, object: object, turn: job_turn(agent.uid)}
  end

  test "declares the hosted read subset as read-only Job tools" do
    declarations = Tools.Brain.declarations()

    assert Enum.map(declarations, & &1["name"]) == [
             "recall",
             "entity",
             "whoknows",
             "delta",
             "metric_query"
           ]

    assert Enum.map(declarations, &Map.take(&1, ~w(type strict name description parameters))) ==
             Ankole.Brain.Tools.function_specs(Tools.Brain.operations())

    for declaration <- declarations do
      assert declaration["read_only"] == true
      assert declaration["destructive"] == false
      assert declaration["execution_mode"] == "parallel"
    end
  end

  test "recall runs for the Job's Agent through the read-tool broker", context do
    request = request("recall", %{"query" => "wire format dated facts", "budget_tokens" => 512})

    assert {:ok, result} = ReadToolBroker.handle_read(context.turn, request, %{request_id: "r"})
    assert [claim | _rest] = result["details"]["claims"]
    assert claim["claim"] == "The wire format carries dated facts"
    assert Ankole.JSON.decode!(result["output"]) == result["details"]
    assert Ankole.Brain.Chunker.estimate_tokens(result["output"]) <= 512
    refute result["is_error"]
  end

  test "entity, whoknows, and delta run through the read-tool broker", context do
    assert {:ok, entity_res} =
             ReadToolBroker.handle_read(
               context.turn,
               request("entity", %{"name" => "Wire Format"}),
               %{request_id: "r-entity"}
             )

    assert entity_res["details"]["entity"]["slug"] == context.object.slug

    assert {:ok, whoknows_res} =
             ReadToolBroker.handle_read(
               context.turn,
               request("whoknows", %{"topic" => "wire format"}),
               %{request_id: "r-whoknows"}
             )

    assert is_list(whoknows_res["details"]["experts"])

    since =
      DateTime.utc_now(:microsecond) |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    assert {:ok, delta_res} =
             ReadToolBroker.handle_read(
               context.turn,
               request("delta", %{"since" => since}),
               %{request_id: "r-delta"}
             )

    assert Enum.any?(
             delta_res["details"]["claims"],
             &(&1["claim"] == "The wire format carries dated facts")
           )
  end

  test "a write operation and invalid arguments do not reach Brain", context do
    for write_op <- ~w(remember put_page edit_page forget synthesize learn_source) do
      assert {:error, error} =
               ReadToolBroker.handle_read(
                 context.turn,
                 request(write_op, %{}),
                 %{request_id: "r"}
               )

      assert error["code"] == "unknown_read_tool"

      assert {:error, {:unknown_operation, ^write_op}} =
               Tools.Brain.read(context.turn, write_op, %{})
    end

    assert {:error, error} =
             ReadToolBroker.handle_read(
               context.turn,
               request("recall", %{}),
               %{request_id: "r"}
             )

    assert error["code"] == "read_tool_failed"
    assert error["message"] =~ "query"
  end

  test "a Signal that another Agent owns refuses the read", context do
    %{principal: other} = agent_fixture()
    foreign = job_turn(other.uid)
    %JobTurnRef{} = turn = context.turn
    turn = %JobTurnRef{turn | signal_id: foreign.signal_id}

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
