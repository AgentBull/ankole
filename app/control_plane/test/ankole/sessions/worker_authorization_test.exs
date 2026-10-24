defmodule Ankole.Sessions.WorkerAuthorizationTest do
  use Ankole.DataCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.{AuthZ, Conversations}
  alias Ankole.AgentWorkers.WorkerRoute
  alias Ankole.RuntimeFabric.V1, as: Proto
  alias Ankole.Sessions.{Admission, PendingCall, Tool, Tools, Worker}
  alias Ankole.Signals.Signal

  test "rendered web fetch dispatch retains the public tool grant and normalized arguments" do
    human = human_fixture().principal
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: human.uid}).principal
    Ankole.ConversationsFixtures.grant_chat(human.uid, agent.uid)

    assert {:ok, permission} =
             AuthZ.create_permission_grant(%{
               principal_uid: human.uid,
               resource_pattern: "agent:#{agent.uid}:tool:web_fetch",
               action: "invoke",
               condition:
                 ~s(context.request.ip == "10.20.1.10" && context.request.args.result_offset == 17)
             })

    conversation_id = Ecto.UUID.generate()

    assert {:ok, _} =
             Conversations.create(
               Ankole.PrincipalsFixtures.actor_fixture(actor_context(human.uid, "10.20.1.10")),
               %{
                 conversation_id: conversation_id,
                 message_id: Ecto.UUID.generate(),
                 agent_uid: agent.uid,
                 text: "Read this page"
               }
             )

    signal = Repo.get_by!(Signal, conversation_id: conversation_id)
    assert {:ok, run} = Admission.admit(signal, signal)

    assert {:ok, response} =
             Ankole.AIGatewayCase.start_response_run(%{
               subject_uid: agent.uid,
               conversation_id: run.conversation.id
             })

    tool =
      Tools.Web.declarations()
      |> Enum.find(&(&1["name"] == "web_fetch"))
      |> Tool.new(Tools.Web)

    run = %{run | tools: [tool], model_response: response}
    args = %{"urls" => ["https://example.com/report"], "result_offset" => 17}
    call = %{"name" => "web_fetch", "call_id" => "fetch", "arguments" => Torque.encode!(args)}
    assert {:ok, ^tool, ^args} = Tools.prepare(run, call)

    assert {:delegate, "__rendered_web_fetch" = worker_name, worker_args, continue} =
             Tools.execute(run, call, tool, args)

    pending =
      PendingCall.new_round([call], false)
      |> PendingCall.start("fetch", call, tool, args, true)
      |> PendingCall.delegate("fetch", worker_name, worker_args, continue)

    {_pending, dispatch} = PendingCall.to_worker(pending, "fetch")
    route = "worker-authorization-#{Ecto.UUID.generate()}"
    :ok = WorkerRoute.register_local_worker(route, self())
    on_exit(fn -> WorkerRoute.unregister_local_worker(route) end)
    assert {:ok, row} = Ankole.SessionsCase.admit_worker(route, %{worker_id: agent.uid})

    assert {:ok, :sent_or_queued} = Worker.send_call(run, row, dispatch)
    assert_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, sent}}}
    assert sent.name == "__rendered_web_fetch"
    assert Torque.decode!(sent.arguments_json) == %{"urls" => args["urls"]}

    assert {:ok, _} = AuthZ.delete_permission_grant(permission.id)
    assert {:error, {:forbidden, "invoke"}} = Worker.send_call(run, row, dispatch)
    refute_receive {:actor_lane, %Proto.Envelope{body: {:tool_call, _}}}
  end

  defp actor_context(uid, ip) do
    actor = Ankole.PrincipalsFixtures.actor_fixture(uid)
    %{actor | authn: %{"ip" => ip}}
  end
end
