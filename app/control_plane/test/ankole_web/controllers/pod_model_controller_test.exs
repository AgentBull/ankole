defmodule AnkoleWeb.PodModelControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod
  import Ankole.SessionsCase, only: [agent_fixture: 1]
  alias Ankole.{Conversations, Repo}
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.Sessions.Admission
  alias Ankole.Signals.Signal

  setup %{conn: conn, tenant: tenant} do
    Ankole.AppConfigure.Cache.clear_for_test()

    {conn, human} =
      console_conn_with_principal(pod_conn(conn, tenant))

    agent = agent_fixture(%{owner_principal_uid: human}).principal
    Ankole.ConversationsFixtures.grant_chat(human, agent.uid)
    {:ok, heavy} = ModelProfiles.get_model_profile(agent.uid, "heavy")

    {:ok, _} =
      ModelProfiles.put_model_profile(
        agent.uid,
        "careful",
        Map.put(heavy, "description", "Careful analysis")
      )

    %{conn: conn, human: human, agent: agent}
  end

  test "the browser catalog exposes only configured names and descriptions", ctx do
    response = api_get(ctx.conn, "/api/v2/pod/agents/#{ctx.agent.uid}/model-profiles")

    assert api_response(response, 200) == %{
             "profiles" => [%{"name" => "careful", "description" => "Careful analysis"}]
           }

    refute response.resp_body =~ "provider_id"
    refute response.resp_body =~ "credential"
    refute response.resp_body =~ "sk-test"

    anonymous =
      get(
        build_conn(),
        AnkoleWeb.Plugs.RequestHost.origin(ctx.conn) <>
          "/api/v2/pod/agents/#{ctx.agent.uid}/model-profiles"
      )

    assert api_response(anonymous, 401)["error"]["code"] == "unauthorized"
  end

  test "a custom first model and a later saved preference use the real typed API", ctx do
    id = Ecto.UUID.generate()
    message = Ecto.UUID.generate()

    created =
      api_post(ctx.conn, "/api/v2/pod/conversations", %{
        conversationID: id,
        messageID: message,
        agentUID: ctx.agent.uid,
        text: "Use careful analysis",
        modelProfile: "careful"
      })

    assert api_response(created, 200)["conversation"]["id"] == id
    assert Repo.get_by!(Signal, message_id: message).data["model_profile"] == "careful"

    current =
      created |> recycle_api() |> api_get("/api/v2/pod/conversations/#{id}/model-profile")

    assert %{"profile" => "careful", "activeProfile" => nil} = api_response(current, 200)

    saved =
      current
      |> recycle_api()
      |> api_put("/api/v2/pod/conversations/#{id}/model-profile", %{profile: nil})

    assert %{"profile" => nil} = api_response(saved, 200)

    reopened =
      saved |> recycle_api() |> api_get("/api/v2/pod/conversations/#{id}/model-profile")

    assert %{"profile" => nil} = api_response(reopened, 200)
  end

  test "a different active model returns a recoverable conflict and queued responses identify their model",
       ctx do
    id = Ecto.UUID.generate()

    {:ok, detail} =
      Conversations.create(Ankole.PrincipalsFixtures.actor_fixture(ctx.human), %{
        conversation_id: id,
        message_id: Ecto.UUID.generate(),
        agent_uid: ctx.agent.uid,
        text: "Current work"
      })

    input = Repo.get_by!(Signal, conversation_id: id)

    assert {:ok, _run} =
             Admission.admit(%{agent_uid: ctx.agent.uid, session_id: detail.session_id}, input)

    changed =
      api_put(ctx.conn, "/api/v2/pod/conversations/#{id}/model-profile", %{profile: "careful"})

    assert %{"profile" => "careful", "activeProfile" => "primary"} = api_response(changed, 200)

    rejected =
      changed
      |> recycle_api()
      |> api_post("/api/v2/pod/conversations/#{id}/messages", %{
        messageID: Ecto.UUID.generate(),
        text: "Next model",
        deliveryMode: "steer"
      })

    assert %{"errors" => [%{"code" => "requires_queue_for_profile"}]} =
             api_response(rejected, 409)

    queued =
      rejected
      |> recycle_api()
      |> api_post("/api/v2/pod/conversations/#{id}/messages", %{
        messageID: Ecto.UUID.generate(),
        text: "Next model",
        deliveryMode: "queue"
      })

    assert [%{"modelProfile" => "careful", "deliveryMode" => "queue"}] =
             api_response(queued, 200)["pendingQueues"]
             |> Enum.find(&(&1["agentUID"] == ctx.agent.uid))
             |> Map.fetch!("inputs")
  end
end
