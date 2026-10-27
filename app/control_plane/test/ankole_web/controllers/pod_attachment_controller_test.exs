defmodule AnkoleWeb.PodAttachmentControllerTest do
  use AnkoleWeb.ConnCase, async: false
  import AnkoleWeb.PodAPI
  @moduletag host: :pod
  import Ecto.Query
  alias Ankole.{BrowserSessions, Files, Repo}
  alias Ankole.Conversations.Message
  alias Ankole.Pod.Pages
  alias AnkoleWeb.Session, as: WebSession
  alias AnkoleWeb.SessionCookies

  setup do
    Ankole.AppConfigure.Cache.clear_for_test()
    :ok
  end

  test "a native browser upload is not a Page; its attachment-only Message and frozen download survive reads",
       %{conn: conn} do
    {conn, uid} = console_conn_with_principal(conn)
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: uid}).principal
    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)
    bytes = "Human's file contents"
    local = Files.temp_path()
    File.write!(local, bytes)
    on_exit(fn -> File.rm(local) end)
    upload = %Plug.Upload{path: local, filename: "brief.txt", content_type: "text/plain"}
    count = Repo.aggregate(Ankole.Pod.Page, :count)

    result =
      post(conn, "/api/v2/pod/attachments", %{file: upload, fileID: Ecto.UUID.generate()})

    receipt = Phoenix.ConnTest.json_response(result, 200)["receipt"]
    assert is_binary(receipt)
    assert Repo.aggregate(Ankole.Pod.Page, :count) == count

    id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()

    created =
      result
      |> recycle_api()
      |> api_post("/api/v2/pod/conversations", %{
        conversationID: id,
        messageID: message_id,
        agentUID: agent.uid,
        text: "",
        attachments: [receipt]
      })

    assert %{
             "conversation" => %{"title" => "brief.txt"},
             "messages" => [%{"attachments" => [attachment]}]
           } =
             api_response(created, 200)

    refreshed = created |> recycle_api() |> api_get("/api/v2/pod/conversations/#{id}")

    assert hd(Phoenix.ConnTest.json_response(refreshed, 200)["messages"])[
             "attachments"
           ] == [attachment]

    download =
      refreshed
      |> recycle_api()
      |> get("/api/v2/pod/conversations/#{id}/attachments/#{message_id}", %{
        path: attachment["path"]
      })

    assert response(download, 200) == bytes
    assert get_resp_header(download, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(download, "content-security-policy") == ["sandbox; default-src 'none'"]

    assert get_resp_header(download, "content-disposition") == [
             "inline; filename*=UTF-8''brief.txt"
           ]

    assert Repo.aggregate(Ankole.Pod.Page, :count) == count
    assert Repo.aggregate(Message, :count) == 1
  end

  test "active file contents download instead of executing, and invalid IDs return missing", %{
    conn: conn
  } do
    {conn, uid} = console_conn_with_principal(conn)
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: uid}).principal
    Ankole.ConversationsFixtures.grant_chat(uid, agent.uid)
    local = Files.temp_path()
    File.write!(local, "<script>throw new Error('must not execute')</script>")
    on_exit(fn -> File.rm(local) end)
    upload = %Plug.Upload{path: local, filename: "active.html", content_type: "text/html"}

    stored =
      post(conn, "/api/v2/pod/attachments", %{file: upload, fileID: Ecto.UUID.generate()})

    receipt = json_response(stored, 200)["receipt"]
    id = Ecto.UUID.generate()
    message_id = Ecto.UUID.generate()

    created =
      stored
      |> recycle_api()
      |> api_post("/api/v2/pod/conversations", %{
        conversationID: id,
        messageID: message_id,
        agentUID: agent.uid,
        text: "Read the file",
        attachments: [receipt]
      })

    path = hd(hd(api_response(created, 200)["messages"])["attachments"])["path"]

    download =
      created
      |> recycle_api()
      |> get("/api/v2/pod/conversations/#{id}/attachments/#{message_id}", %{path: path})

    assert response(download, 200) =~ "<script>"
    assert [disposition] = get_resp_header(download, "content-disposition")
    assert String.starts_with?(disposition, "attachment;")

    missing =
      download
      |> recycle_api()
      |> get("/api/v2/pod/conversations/#{id}/attachments/not-a-uuid", %{path: path})

    assert response(missing, 404)
  end

  test "the upload checks the existing transfer size bound before storing bytes", %{conn: conn} do
    {conn, _uid} = console_conn_with_principal(conn)
    local = Files.temp_path()
    {:ok, handle} = :file.open(String.to_charlist(local), [:write, :binary])
    {:ok, _} = :file.position(handle, Ankole.WorkerFiles.max_transfer_bytes())
    :ok = :file.write(handle, <<0>>)
    :ok = :file.close(handle)
    on_exit(fn -> File.rm(local) end)

    upload = %Plug.Upload{
      path: local,
      filename: "too-large.bin",
      content_type: "application/octet-stream"
    }

    response =
      post(conn, "/api/v2/pod/attachments", %{file: upload, fileID: Ecto.UUID.generate()})

    assert %{"error" => %{"code" => "file_too_large"}} =
             Phoenix.ConnTest.json_response(response, 413)

    assert Repo.aggregate(Message, :count) == 0
  end

  test "an attachment belongs to its current Chat member and explicit Save makes a separate Page reference",
       %{conn: conn} do
    {_conn, uid} = console_conn_with_principal(conn)
    reader = Ankole.PrincipalsFixtures.human_fixture().principal
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: reader.uid}).principal
    Ankole.ConversationsFixtures.grant_chat(reader.uid, agent.uid)

    {:ok, page} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(uid), %{title: "Shared doc"})

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(uid, page.id, %{
        inherit_permissions: false,
        grants: [%{principal_uid: reader.uid, role: "view"}]
      })

    local = Files.temp_path()
    File.write!(local, "Durable saved contents")
    on_exit(fn -> File.rm(local) end)

    {:ok, upload} =
      Ankole.Conversations.Attachments.Native.upload(
        Ankole.PrincipalsFixtures.actor_fixture(reader.uid),
        Ecto.UUID.generate(),
        "saved.txt",
        {:file, local},
        "text/plain"
      )

    {:ok, detail} =
      Ankole.ConversationsFixtures.create(reader.uid, %{
        conversation_id: Ecto.UUID.generate(),
        message_id: Ecto.UUID.generate(),
        agent_uid: agent.uid,
        page_id: page.id,
        access_scope: :participants,
        text: "",
        attachments: [upload.receipt]
      })

    message = hd(detail.messages)
    attachment = hd(message.attachments)

    {:ok, saved} =
      Pages.create(Ankole.PrincipalsFixtures.actor_fixture(reader.uid), %{
        type: "file",
        title: "Saved",
        private_owner_uid: reader.uid
      })

    assert {:ok, _} =
             Ankole.Pod.Files.copy_from_message(
               Ankole.PrincipalsFixtures.actor_fixture(reader.uid),
               saved.id,
               0,
               message.id,
               attachment["path"]
             )

    assert {:ok, _, "Durable saved contents"} =
             Ankole.Pod.Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(reader.uid),
               saved.id,
               "saved.txt"
             )

    {:ok, _} =
      Ankole.Pod.PagesFixtures.set_sharing(uid, page.id, %{inherit_permissions: false, grants: []})

    assert {:error, :forbidden} =
             Pages.get(Ankole.PrincipalsFixtures.actor_fixture(reader.uid), page.id)

    assert {:ok, posted} =
             Ankole.ConversationsFixtures.post(reader.uid, detail.conversation.id, %{
               message_id: Ecto.UUID.generate(),
               text: "Continue the private Chat"
             })

    assert posted.conversation.native_access_scope == :participants

    assert {:ok, ^attachment} =
             Ankole.Conversations.Attachments.Native.read_to_file(
               Ankole.PrincipalsFixtures.actor_fixture(reader.uid),
               detail.conversation.id,
               message.id,
               attachment["path"],
               local
             )

    Repo.delete_all(
      from p in Ankole.Conversations.Participant,
        where: p.conversation_id == ^detail.conversation.id and p.principal_uid == ^reader.uid
    )

    assert {:error, :not_found} =
             Ankole.Conversations.Attachments.Native.read_to_file(
               Ankole.PrincipalsFixtures.actor_fixture(reader.uid),
               detail.conversation.id,
               message.id,
               attachment["path"],
               local
             )

    assert {:ok, _, "Durable saved contents"} =
             Ankole.Pod.Files.read(
               Ankole.PrincipalsFixtures.actor_fixture(reader.uid),
               saved.id,
               "saved.txt"
             )

    assert Repo.get_by!(Message, id: message.id).attachments == [attachment]
  end

  test "native attachment links select only the account proven by the browser cookies", %{
    tenant: tenant
  } do
    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    original = Application.fetch_env!(:ankole, AnkoleWeb.Endpoint)
    configured = Keyword.put(original, :url, host: "ankole.localhost", port: 4002)
    Application.put_env(:ankole, AnkoleWeb.Endpoint, configured)
    AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, configured}], [])

    on_exit(fn ->
      Application.put_env(:ankole, AnkoleWeb.Endpoint, original)
      AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, original}], [])
    end)

    owner = Ankole.PrincipalsFixtures.human_fixture().principal
    other = Ankole.PrincipalsFixtures.human_fixture().principal
    foreign = Ankole.PrincipalsFixtures.human_fixture().principal
    agent = Ankole.PrincipalsFixtures.agent_fixture(%{owner_principal_uid: owner.uid}).principal
    Ankole.ConversationsFixtures.grant_chat(owner.uid, agent.uid)
    local = Files.temp_path()
    bytes = "The selected account's frozen file"
    File.write!(local, bytes)
    on_exit(fn -> File.rm(local) end)

    assert {:ok, upload} =
             Ankole.Conversations.Attachments.Native.upload(
               Ankole.PrincipalsFixtures.actor_fixture(owner.uid),
               Ecto.UUID.generate(),
               "selected.txt",
               {:file, local},
               "text/plain"
             )

    assert {:ok, detail} =
             Ankole.ConversationsFixtures.create(owner.uid, %{
               conversation_id: Ecto.UUID.generate(),
               message_id: Ecto.UUID.generate(),
               agent_uid: agent.uid,
               text: "",
               attachments: [upload.receipt]
             })

    message = hd(detail.messages)
    attachment = hd(message.attachments)
    host = tenant.slug <> ".ankole.localhost"
    {first, owner_ref} = browser_login(host, %{}, owner)
    first_cookies = response_cookies(send_resp(first, 200, ""))
    {second, other_ref} = browser_login(host, first_cookies, other)
    cookies = Map.merge(first_cookies, response_cookies(send_resp(second, 200, "")))
    browser = WebSession.browser_reference(second)
    assert BrowserSessions.current_reference(browser) == other_ref

    path =
      "/api/v2/pod/conversations/#{detail.conversation.id}/attachments/#{message.id}"

    selected = attachment_get(host, cookies, path, attachment["path"], owner_ref)
    assert get_req_header(selected, "x-ankole-authentication") == []
    assert get_req_header(selected, "x-ankole-pod") == []
    assert response(selected, 200) == bytes
    assert BrowserSessions.current_reference(browser) == other_ref

    denied = attachment_get(host, cookies, path, attachment["path"], other_ref)
    assert json_response(denied, 404)["error"]["code"] == "not_found"

    missing_proof = Map.delete(cookies, SessionCookies.authentication_prefix() <> owner_ref["id"])
    assert attachment_get(host, missing_proof, path, attachment["path"], owner_ref).status == 401

    {foreign_login, foreign_ref} = browser_login(host, %{}, foreign)
    foreign_cookies = response_cookies(send_resp(foreign_login, 200, ""))
    foreign_name = SessionCookies.authentication_prefix() <> foreign_ref["id"]
    transplanted = Map.put(cookies, foreign_name, Map.fetch!(foreign_cookies, foreign_name))
    assert attachment_get(host, transplanted, path, attachment["path"], foreign_ref).status == 401

    ordinary_api =
      cookie_request(host, cookies)
      |> get("http://#{host}:4002/api/v2/pod/conversations/#{detail.conversation.id}", %{
        authentication_ref: BrowserSessions.encode_reference(owner_ref)
      })

    assert ordinary_api.status == 401

    Repo.delete_all(
      from p in Ankole.Conversations.Participant,
        where: p.conversation_id == ^detail.conversation.id and p.principal_uid == ^owner.uid
    )

    assert attachment_get(host, cookies, path, attachment["path"], owner_ref).status == 404
  end

  defp attachment_get(host, cookies, path, file_path, reference) do
    cookie_request(host, cookies)
    |> get("http://#{host}:4002" <> path, %{
      path: file_path,
      authentication_ref: BrowserSessions.encode_reference(reference)
    })
  end

  defp cookie_request(host, cookies) do
    Enum.reduce(cookies, build_conn(:get, "http://#{host}:4002/"), fn {name, value}, conn ->
      Plug.Test.put_req_cookie(conn, name, value)
    end)
  end

  defp response_cookies(conn),
    do: Map.new(conn.resp_cookies, fn {name, cookie} -> {name, cookie.value} end)

  defp browser_login(host, cookies, principal) do
    conn =
      cookie_request(host, cookies)
      |> Map.put(:secret_key_base, AnkoleWeb.Endpoint.config(:secret_key_base))
      |> SessionCookies.call([])
      |> fetch_session()

    conn = WebSession.ensure_browser(conn)

    {:ok, %{browser: browser, authentication: auth}} =
      BrowserSessions.authenticate(WebSession.browser_reference(conn), :pod, %{
        "principal_uid" => principal.uid,
        "access_version" => principal.access_version,
        "provider_id" => "local",
        "external_id" => principal.uid
      })

    conn = WebSession.put_authentication(conn, browser, auth)

    {conn, WebSession.authentication_reference(conn)}
  end
end
