defmodule AnkoleWeb.PodRuntimeContextTest do
  use AnkoleWeb.ConnCase, async: false

  import AnkoleWeb.PodAPI

  alias Ankole.{AuthZ, Conversations, Repo}
  alias Ankole.Pod.{Pages, RPCBroker}
  alias Ankole.RuntimeFabric.V1.PodRequest
  alias Ankole.Sessions.{Admission, Run, RunRef, Tool, Tools}
  alias Ankole.Signals.Signal

  @moduletag host: :pod
  @allowed_ip {10, 20, 1, 10}
  @other_ip {10, 20, 1, 12}
  @ip_condition ~s(context.request.ip == "10.20.1.10")

  setup %{conn: conn} do
    {conn, human} = console_conn_with_principal(conn)
    agent = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: human}).principal
    %{conn: conn, human: human, agent: agent}
  end

  test "native chat uses the ingress IP and stores it with each accepted input", ctx do
    grant(ctx.human, "agent:#{ctx.agent.uid}", "chat", @ip_condition)
    denied = create_chat(ctx, @other_ip)
    assert api_error(denied, 403)["code"] == "forbidden"
    assert Repo.aggregate(Signal, :count) == 0

    accepted = create_chat(ctx, @allowed_ip)
    id = api_response(accepted, 200)["conversation"]["id"]
    signal = Repo.get_by!(Signal, conversation_id: id)

    assert %{
             "ip" => "10.20.1.10",
             "surface" => "pod_browser",
             "authn" => %{
               "ip" => "10.20.1.10",
               "provider_scope" => "tenant",
               "provider_id" => "lark-main",
               "amr" => ["oidc"],
               "challenge_started_at" => started
             }
           } = signal.data["request_context"]

    assert {:ok, _, _} = DateTime.from_iso8601(started)

    denied_post =
      accepted
      |> recycle_api()
      |> Map.put(:remote_ip, @other_ip)
      |> api_post("/api/v2/pod/conversations/#{id}/messages", %{
        messageID: Ecto.UUID.generate(),
        text: "Follow up"
      })

    assert api_error(denied_post, 403)["code"] == "forbidden"
    assert Repo.aggregate(Signal, :count) == 1
  end

  test "tool authorization restores the original IP and normalized args after run rebuild", ctx do
    grant(ctx.human, "agent:#{ctx.agent.uid}", "chat")

    grant(
      ctx.human,
      "agent:#{ctx.agent.uid}:tool:clarify",
      "invoke",
      @ip_condition <>
        ~s( && context.request.surface == "agent_tool" && context.request.args.question == "Choose")
    )

    run = create_run(ctx, @allowed_ip)
    assert_tool(run, :allowed)
    assert {:ok, %{event: event}} = Run.rebuild(run)
    assert {:ok, rebuilt} = Admission.admit(run, event)
    assert rebuilt.epoch > run.epoch

    assert_tool(rebuilt, :allowed)

    denied = create_run(ctx, @other_ip)
    assert_tool(denied, :denied)
  end

  test "RPC restores the same persisted IP for both the agent and the human", ctx do
    grant(ctx.human, "agent:#{ctx.agent.uid}", "chat")
    owner = Ankole.PrincipalsFixtures.human_fixture().principal

    assert {:ok, page} =
             Pages.create(Ankole.PrincipalsFixtures.actor_fixture(owner.uid), %{
               title: "IP protected"
             })

    assert {:ok, _} =
             Ankole.Pod.PagesFixtures.set_sharing(owner.uid, page.id, %{
               inherit_permissions: false,
               grants: [%{principal_uid: owner.uid, role: "manage"}]
             })

    pattern = "pod:**:#{page.id}:page"
    condition = @ip_condition <> ~s( && context.request.surface == "agent_rpc")
    human_grant = grant(ctx.human, pattern, "page_view", condition)
    agent_grant = grant(ctx.agent.uid, pattern, "page_view", condition)
    run = create_run(ctx, @allowed_ip)

    assert page.id in rpc_page_ids(run)
    assert {:ok, %{event: event}} = Run.rebuild(run)
    assert {:ok, rebuilt} = Admission.admit(run, event)
    assert page.id in rpc_page_ids(rebuilt)
    denied = create_run(ctx, @other_ip)
    refute page.id in rpc_page_ids(denied)

    assert {:ok, _} = AuthZ.delete_permission_grant(human_grant.id)
    refute page.id in rpc_page_ids(rebuilt)
    grant(ctx.human, pattern, "page_view", condition)
    assert {:ok, _} = AuthZ.delete_permission_grant(agent_grant.id)
    refute page.id in rpc_page_ids(rebuilt)
  end

  @tag capture_log: true
  test "missing historical facts and external payloads cannot supply a trusted IP", ctx do
    grant(ctx.human, "agent:#{ctx.agent.uid}", "chat")
    grant(ctx.human, "agent:#{ctx.agent.uid}:tool:clarify", "invoke", @ip_condition)

    assert {:ok, _} =
             Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.human), %{
               conversation_id: Ecto.UUID.generate(),
               message_id: Ecto.UUID.generate(),
               agent_uid: ctx.agent.uid,
               text: "No browser origin",
               request_context: %{
                 "ip" => "10.20.1.10",
                 "authn" => %{"provider_scope" => "tenant", "amr" => ["mfa"]}
               }
             })

    original = Repo.one!(Signal)
    assert original.data["request_context"] == %{"authn" => %{}}

    original
    |> AshPostgres.DataLayer.to_ecto()
    |> Ecto.Changeset.change(data: Map.delete(original.data, "request_context"))
    |> Repo.update!()

    event = Repo.get!(Signal, original.id)
    assert {:ok, run} = Admission.admit(event, event)
    assert Conversations.request_context(run.event) == %{}
    assert_tool(run, :denied)

    for untrusted <- [
          %{event | producer: :external},
          %{event | source: "webhook:untrusted"},
          %{event | type: "webhook.message"},
          %{event | session_id: "external-session"}
        ] do
      forged = %{
        untrusted
        | data: %{
            "request_context" => %{
              "ip" => "10.20.1.10",
              "authn" => %{"provider_scope" => "tenant", "amr" => ["mfa"]}
            }
          }
      }

      assert Conversations.request_context(forged) == %{}
      assert_tool(%{run | event: forged}, :denied)
    end

    historical = %{event | data: Map.delete(event.data, "request_context")}
    assert Conversations.request_context(historical) == %{}
    assert_tool(%{run | event: historical}, :denied)
  end

  defp create_chat(ctx, ip) do
    ctx.conn
    |> recycle_api()
    |> Map.put(:remote_ip, ip)
    |> api_post("/api/v2/pod/conversations", %{
      conversationID: Ecto.UUID.generate(),
      messageID: Ecto.UUID.generate(),
      agentUID: ctx.agent.uid,
      text: "Use the protected operation"
    })
  end

  defp create_run(ctx, ip) do
    id = create_chat(ctx, ip) |> api_response(200) |> get_in(["conversation", "id"])
    event = Repo.get_by!(Signal, conversation_id: id)
    assert {:ok, run} = Admission.admit(event, event)
    run
  end

  defp assert_tool(run, expected) do
    tool =
      Tools.Session.declarations()
      |> Enum.find(&(&1["name"] == "clarify"))
      |> Tool.new(Tools.Session)

    run = %{run | tools: [tool]}
    call = %{"name" => "clarify", "arguments" => ~s({"question":"  Choose  "})}

    case expected do
      :allowed ->
        assert {:ok, ^tool, %{"question" => "Choose"}} = Tools.prepare(run, call)

        assert {:error, %{failure_kind: "forbidden"}} =
                 Tools.prepare(run, %{call | "arguments" => ~s({"question":"Other"})})

      :denied ->
        assert {:error, %{failure_kind: "forbidden"}} = Tools.prepare(run, call)
    end
  end

  defp rpc_page_ids(run) do
    ref = %RunRef{agent_uid: run.agent_uid, session_id: run.session_id, signal_id: run.signal_id}
    ctx = %{worker_id: run.agent_uid, route: "unused", request_id: "ip-policy"}
    request = %PodRequest{operation: "pages.list", params_json: "{}"}
    assert {:ok, %{"result" => result}} = RPCBroker.handle_read(ref, request, ctx)
    Enum.map(result, & &1["id"])
  end

  defp grant(uid, resource, action, condition \\ "true") do
    assert {:ok, grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: uid,
               resource_pattern: resource,
               action: action,
               condition: condition
             })

    grant
  end
end
