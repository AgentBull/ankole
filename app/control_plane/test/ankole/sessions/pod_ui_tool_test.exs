defmodule Ankole.Sessions.PodUIToolTest do
  @moduledoc "Checks that an Agent's Pod page operations reach the Human's tab and come back as tool results."
  use Ankole.DataCase, async: false
  import Ankole.AIGatewayCase, only: [start_response_run: 1]
  import Ankole.PrincipalsFixtures, only: [human_fixture: 1, actor_fixture: 1]
  require Ash.Query

  alias Ankole.AIGateway.ResponseCommit
  alias Ankole.Conversations
  alias Ankole.Pod.AgentUIRequest
  alias Ankole.Sessions.{Admission, Context, ToolCatalog, Tools, Wait}
  alias Ankole.Sessions.Tools.PodUI
  alias Ankole.Signals.Signal

  setup do
    alice = human_fixture(%{display_name: "Alice"}).principal
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: alice.uid}).principal
    Ankole.ConversationsFixtures.grant_chat(alice.uid, agent.uid)
    id = Ecto.UUID.generate()

    {:ok, _} =
      Conversations.create(actor_fixture(alice), %{
        conversation_id: id,
        agent_uid: agent.uid,
        message_id: Ecto.UUID.generate(),
        text: "Rename the project to Atlas."
      })

    event = Repo.one!(from s in Signal, where: s.conversation_id == ^id)
    {:ok, run} = Admission.admit(%{agent_uid: agent.uid, session_id: event.session_id}, event)
    {:ok, context} = Context.resolve(run.agent_uid, run.session_id)
    run = %{run | context: context}
    {tools, _hosted} = ToolCatalog.for_run(run)
    %{alice: alice, agent: agent, run: %{run | tools: tools}}
  end

  test "a turn that works for a Human offers the Pod page tools", %{run: run} do
    names = Enum.map(run.tools, & &1.name)
    assert "pod_ui_snapshot" in names
    assert "pod_ui_act" in names
    assert "pod_ui_query" in names
    assert PodUI.declarations(%{run | kind: :ambient}) == []
  end

  test "an act call commits one request for the Human's tab and waits for its answer", ctx do
    Phoenix.PubSub.subscribe(
      Ankole.PubSub,
      Ankole.Pod.AgentUI.topic(Repo.tenant_id!(), ctx.alice.uid)
    )

    steps = [%{"ref" => "Project name", "action" => "setValue", "args" => ["Atlas"]}]

    call = %{
      "type" => "function_call",
      "name" => "pod_ui_act",
      "call_id" => "act-1",
      "arguments" => Ankole.JSON.encode!(%{"steps" => steps})
    }

    {:ok, response} =
      start_response_run(%{subject_uid: ctx.agent.uid, conversation_id: ctx.run.conversation.id})

    {:ok, response} = ResponseCommit.commit_complete(response, [call])
    run = %{ctx.run | model_response: response}

    assert {:ok, tool, args} = Tools.prepare(run, call)

    assert {:await, %Wait{kind: :ui, ui_request_id: id} = wait} =
             Tools.execute(run, call, tool, args)

    assert_receive {:agent_ui_request, ^id}

    request = Ankole.Ash.read_one!(Ash.Query.filter(AgentUIRequest, id == ^id))
    assert %{operation: :act, status: :pending, arguments: %{"steps" => ^steps}} = request
    assert request.principal_uid == ctx.alice.uid

    # A recovered turn replays the receipt and waits for the same request.
    assert {:await, %Wait{ui_request_id: ^id}} = Tools.execute(run, call, tool, args)
    assert :pending = Tools.observe(run, wait)

    claim!(id)

    finish!(id, %{
      status: :done,
      result: %{"ok" => true, "values" => %{"Project name" => "Atlas"}}
    })

    assert {:ready, result, []} = Tools.observe(run, wait)
    refute result.is_error
    assert result.details == %{"ok" => true, "values" => %{"Project name" => "Atlas"}}
  end

  test "an unclaimed request tells the Agent that no tab is open", ctx do
    request = open!(ctx, :snapshot)

    wait = %Wait{
      kind: :ui,
      ui_request_id: request.id,
      timeout_ms: 30_000,
      started_at: DateTime.utc_now()
    }

    assert {:ready, result, []} = PodUI.observe(ctx.run, wait, false, true)
    assert result.is_error
    assert result.output =~ "no Pod tab open"

    assert %{status: :expired} =
             Ankole.Ash.read_one!(Ash.Query.filter(AgentUIRequest, id == ^request.id))
  end

  test "a claimed request that never answers reports an unknown outcome", ctx do
    request = open!(ctx, :act)
    claim!(request.id)

    wait = %Wait{
      kind: :ui,
      ui_request_id: request.id,
      timeout_ms: 1,
      started_at: DateTime.utc_now()
    }

    assert :pending = PodUI.observe(ctx.run, wait, false, false)
    assert {:ready, result, []} = PodUI.observe(ctx.run, wait, false, true)
    assert result.failure_kind == "interrupted"
  end

  test "a failure from the page reaches the Agent as an error", ctx do
    request = open!(ctx, :query)
    claim!(request.id)
    finish!(request.id, %{status: :failed, error: "Nothing is named Region."})

    wait = %Wait{
      kind: :ui,
      ui_request_id: request.id,
      timeout_ms: 30_000,
      started_at: DateTime.utc_now()
    }

    assert {:ready, result, []} = PodUI.observe(ctx.run, wait, false, false)
    assert result.is_error
    assert result.output =~ "Nothing is named Region."
  end

  defp open!(ctx, operation) do
    Ankole.Ash.create!(AgentUIRequest, :open_in_tx, %{
      agent_uid: ctx.agent.uid,
      principal_uid: ctx.alice.uid,
      operation: operation,
      arguments: %{}
    })
  end

  defp claim!(id) do
    {:ok, [_]} =
      Ankole.Ash.update_where(Ash.Query.filter(AgentUIRequest, id == ^id), :claim, %{})
  end

  defp finish!(id, answer) do
    {:ok, [_]} =
      Ankole.Ash.update_where(Ash.Query.filter(AgentUIRequest, id == ^id), :finish, answer)
  end
end
