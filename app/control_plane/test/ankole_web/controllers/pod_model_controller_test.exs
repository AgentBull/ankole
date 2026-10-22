defmodule AnkoleWeb.PodModelControllerTest do
  use AnkoleWeb.ConnCase, async: false
  @moduletag host: :pod
  import Phoenix.ConnTest, except: [json_response: 2, build_conn: 0]
  import AnkoleWeb.InternalAPIContract, only: [json_response: 2]
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
    response = get(ctx.conn, "/.internal-apis/pod/agents/#{ctx.agent.uid}/model-profiles")

    assert json_response(response, 200) == %{
             "profiles" => [%{"name" => "careful", "description" => "Careful analysis"}]
           }

    refute response.resp_body =~ "provider_id"
    refute response.resp_body =~ "credential"
    refute response.resp_body =~ "sk-test"

    anonymous =
      get(
        build_conn(),
        AnkoleWeb.Plugs.RequestHost.origin(ctx.conn) <>
          "/.internal-apis/pod/agents/#{ctx.agent.uid}/model-profiles"
      )

    assert json_response(anonymous, 401)["error"]["code"] == "unauthorized"
  end

  test "a custom first model and a later saved preference use the real typed API", ctx do
    id = Ecto.UUID.generate()
    message = Ecto.UUID.generate()

    created =
      post(ctx.conn, "/.internal-apis/pod/conversations", %{
        conversationID: id,
        messageID: message,
        agentUID: ctx.agent.uid,
        text: "Use careful analysis",
        modelProfile: "careful"
      })

    assert json_response(created, 200)["conversation"]["id"] == id
    assert Repo.get_by!(Signal, message_id: message).data["model_profile"] == "careful"

    current =
      created |> recycle_api() |> get("/.internal-apis/pod/conversations/#{id}/model-profile")

    assert %{"profile" => "careful", "activeProfile" => nil} = json_response(current, 200)

    saved =
      current
      |> recycle_api()
      |> put("/.internal-apis/pod/conversations/#{id}/model-profile", %{profile: nil})

    assert %{"profile" => nil} = json_response(saved, 200)

    reopened =
      saved |> recycle_api() |> get("/.internal-apis/pod/conversations/#{id}/model-profile")

    assert %{"profile" => nil} = json_response(reopened, 200)
  end

  test "a different active model returns a recoverable conflict and queued responses identify their model",
       ctx do
    id = Ecto.UUID.generate()

    {:ok, detail} =
      Conversations.create(ctx.human, %{
        conversation_id: id,
        message_id: Ecto.UUID.generate(),
        agent_uid: ctx.agent.uid,
        text: "Current work"
      })

    input = Repo.get_by!(Signal, conversation_id: id)

    assert {:ok, _run} =
             Admission.admit(%{agent_uid: ctx.agent.uid, session_id: detail.session_id}, input)

    changed =
      put(ctx.conn, "/.internal-apis/pod/conversations/#{id}/model-profile", %{profile: "careful"})

    assert %{"profile" => "careful", "activeProfile" => "primary"} = json_response(changed, 200)

    rejected =
      changed
      |> recycle_api()
      |> post("/.internal-apis/pod/conversations/#{id}/messages", %{
        messageID: Ecto.UUID.generate(),
        text: "Next model",
        deliveryMode: "steer"
      })

    assert %{"error" => %{"code" => "requires_queue_for_profile"}} = json_response(rejected, 409)

    queued =
      rejected
      |> recycle_api()
      |> post("/.internal-apis/pod/conversations/#{id}/messages", %{
        messageID: Ecto.UUID.generate(),
        text: "Next model",
        deliveryMode: "queue"
      })

    assert [%{"modelProfile" => "careful", "deliveryMode" => "queue"}] =
             json_response(queued, 200)["pendingInputs"]
  end
end
