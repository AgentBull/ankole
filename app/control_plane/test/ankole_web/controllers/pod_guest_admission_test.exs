defmodule AnkoleWeb.PodGuestAdmissionTest do
  use AnkoleWeb.ConnCase, async: false

  import AnkoleWeb.PodAPI
  import Ankole.PrincipalsFixtures, only: [human_fixture: 1]

  alias Ankole.{AppConfigure, BrowserSessions, Conversations, Files, Repo}
  alias Ankole.Conversations.Attachments.Native, as: Attachments
  alias AnkoleWeb.Session, as: WebSession

  @moduletag host: :pod

  setup do
    AppConfigure.Cache.clear_for_test()
    {:ok, true} = AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    :ok
  end

  test "a guest cannot read an ungranted Agent's model catalog", %{conn: conn} do
    guest = human_fixture(%{membership: :guest}).principal
    conn = login(conn, guest)
    agent = Ankole.SessionsCase.agent_fixture(%{}).principal
    denied = api_get(conn, "/api/v2/pod/agents/#{agent.uid}/model-profiles")
    assert api_error(denied, 403)["code"] == "forbidden"
  end

  for membership <- [:member, :guest] do
    test "#{membership} Agent and model directories require each Agent's chat grant", %{
      conn: conn
    } do
      human = human_fixture(%{membership: unquote(membership)}).principal
      conn = login(conn, human)
      allowed = Ankole.SessionsCase.agent_fixture(%{display_name: "Allowed"}).principal
      hidden = Ankole.SessionsCase.agent_fixture(%{display_name: "Hidden"}).principal

      assert api_response(api_get(conn, "/api/v2/pod/agents"), 200) == %{"agents" => []}

      denied = api_get(conn, "/api/v2/pod/agents/#{hidden.uid}/model-profiles")
      assert api_error(denied, 403)["code"] == "forbidden"

      Ankole.ConversationsFixtures.grant_chat(human.uid, allowed.uid)

      assert api_response(api_get(conn, "/api/v2/pod/agents"), 200) == %{
               "agents" => [
                 %{
                   "uid" => allowed.uid,
                   "displayName" => "Allowed",
                   "active" => true,
                   "avatarURL" => allowed.avatar_url,
                   "type" => "agent",
                   "mayIntervene" => false,
                   "modelProfile" => nil
                 }
               ]
             }

      assert %{"profiles" => []} =
               api_response(
                 api_get(conn, "/api/v2/pod/agents/#{allowed.uid}/model-profiles"),
                 200
               )

      assert api_error(api_get(conn, "/api/v2/pod/agents/#{hidden.uid}/model-profiles"), 403)[
               "code"
             ] == "forbidden"
    end
  end

  test "disabling external guests rejects every conversation HTTP entry", %{conn: conn} do
    guest = human_fixture(%{membership: :guest}).principal
    conn = login(conn, guest)
    agent = Ankole.SessionsCase.agent_fixture(%{}).principal
    Ankole.ConversationsFixtures.grant_chat(guest.uid, agent.uid)
    attrs = conversation_attrs(agent.uid)
    {:ok, detail} = Ankole.ConversationsFixtures.create(guest.uid, attrs)
    id = detail.conversation.id

    assert api_response(api_get(conn, "/api/v2/pod/conversations/#{id}"), 200)["conversation"][
             "id"
           ] == id

    {:ok, false} = AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)

    # The current login policy invalidates the guest proof at the HTTP boundary.
    for path <- [
          "/api/v2/pod/agents",
          "/api/v2/pod/agents/#{agent.uid}/model-profiles",
          "/api/v2/pod/conversations",
          "/api/v2/pod/conversations/#{id}",
          "/api/v2/pod/conversations/#{id}/model-profile",
          "/api/v2/pod/conversations/#{id}/events"
        ] do
      assert json_response(api_get(conn, path), 401)["error"]["code"] == "unauthorized"
    end

    rejected =
      api_post(conn, "/api/v2/pod/conversations/#{id}/messages", %{
        messageID: Ecto.UUID.generate(),
        text: "Denied follow-up"
      })

    assert json_response(rejected, 401)["error"]["code"] == "unauthorized"
    assert Repo.aggregate(Ankole.Conversations.Message, :count) == 1
  end

  test "the guest switch also rejects direct conversation operations", %{conn: conn} do
    guest = human_fixture(%{membership: :guest}).principal
    _conn = login(conn, guest)
    agent = Ankole.SessionsCase.agent_fixture(%{}).principal
    Ankole.ConversationsFixtures.grant_chat(guest.uid, agent.uid)
    attrs = conversation_attrs(agent.uid)
    {:ok, detail} = Ankole.ConversationsFixtures.create(guest.uid, attrs)
    id = detail.conversation.id
    {:ok, false} = AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)

    assert Conversations.list(Ankole.PrincipalsFixtures.actor_fixture(guest.uid)) == []

    assert {:error, :conversation_not_found} =
             Conversations.get(Ankole.PrincipalsFixtures.actor_fixture(guest.uid), id)

    assert {:error, :conversation_not_found} =
             Conversations.visible_native_conversation(
               Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
               id
             )

    assert {:error, _} =
             Conversations.create(
               Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
               conversation_attrs(agent.uid)
             )

    assert {:error, _} =
             Conversations.post(Ankole.PrincipalsFixtures.actor_fixture(guest.uid), id, %{
               message_id: Ecto.UUID.generate(),
               text: "Denied direct follow-up"
             })

    assert Repo.aggregate(Ankole.Conversations.Message, :count) == 1
  end

  test "the guest switch rejects uploads before storage while members can upload", %{conn: conn} do
    guest = human_fixture(%{membership: :guest}).principal
    conn = login(conn, guest)
    local = Files.temp_path()
    File.write!(local, "Guest upload")
    on_exit(fn -> File.rm(local) end)
    file = %Plug.Upload{path: local, filename: "guest.txt", content_type: "text/plain"}

    uploaded =
      conn
      |> post("/api/v2/pod/attachments", %{file: file, fileID: Ecto.UUID.generate()})

    assert %{"receipt" => receipt} = json_response(uploaded, 200)

    assert is_binary(receipt)
    {:ok, false} = AppConfigure.put_tenant_by_key("pod.allow_external_guests", false)
    rejected_bytes = "Rejected guest upload #{Ecto.UUID.generate()}"
    File.write!(local, rejected_bytes)
    digest = :crypto.hash(:sha256, rejected_bytes) |> Base.encode16(case: :lower)

    denied =
      uploaded
      |> recycle_api()
      |> post("/api/v2/pod/attachments", %{file: file, fileID: Ecto.UUID.generate()})

    assert json_response(denied, 401)["error"]["code"] == "unauthorized"

    assert {:error, :forbidden} =
             Attachments.upload(
               Ankole.PrincipalsFixtures.actor_fixture(guest.uid),
               Ecto.UUID.generate(),
               "guest.txt",
               {:file, local},
               "text/plain"
             )

    assert {:error, :not_found} = Files.read_content(digest)

    member = human_fixture(%{membership: :member}).principal

    assert {:ok, %{receipt: member_receipt}} =
             Attachments.upload(
               Ankole.PrincipalsFixtures.actor_fixture(member.uid),
               Ecto.UUID.generate(),
               "member.txt",
               {:file, local},
               "text/plain"
             )

    assert is_binary(member_receipt)
    assert {:ok, ^rejected_bytes} = Files.read_content(digest)
  end

  defp conversation_attrs(agent_uid) do
    %{
      conversation_id: Ecto.UUID.generate(),
      message_id: Ecto.UUID.generate(),
      agent_uid: agent_uid,
      text: "Guest question"
    }
  end

  defp login(conn, principal) do
    conn = conn |> Plug.Test.init_test_session(%{}) |> WebSession.ensure_browser()

    {:ok, %{browser: browser, authentication: auth}} =
      BrowserSessions.authenticate(WebSession.browser_reference(conn), :pod, %{
        "principal_uid" => principal.uid,
        "access_version" => principal.access_version,
        "provider_id" => "local",
        "external_id" => principal.uid
      })

    conn |> WebSession.put_authentication(browser, auth) |> with_console_csrf()
  end
end
