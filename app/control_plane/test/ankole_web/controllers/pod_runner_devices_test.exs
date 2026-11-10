defmodule AnkoleWeb.PodRunnerDevicesTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.{
    AgentWorkers,
    AppConfigure,
    BackgroundAgentJobs,
    BrowserSessions,
    Principals,
    Repo
  }

  alias AnkoleWeb.Session, as: WebSession
  alias Ankole.AgentWorkers.RunnerDevices

  @moduletag host: :pod
  @devices "/api/v2/pod/runner-devices"
  @internal "/api/internal/runner-devices"

  setup do
    {:ok, true} = AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    Ankole.PrincipalsFixtures.worker_provider_fixture(%{is_default: true})
    :ok
  end

  test "members can pair two devices and revoke only the selected device", %{conn: conn} do
    {member, uid} = login_member(conn)
    desktop = register(member, "Research desktop")
    notebook = register(member, "Notebook")

    assert desktop["id"] != notebook["id"]

    assert %{"devices" => [%{"status" => "pairing"}, %{"status" => "pairing"}]} =
             member |> recycle_json() |> get(@devices) |> json_response(200)

    desktop_session = pair(desktop)
    notebook_session = pair(notebook)

    assert %{"error" => %{"code" => "invalid_runner_credential"}} = pair(desktop, 401)

    assert desktop_session["runner_id"] == desktop["id"]
    assert notebook_session["runner_id"] == notebook["id"]

    assistant = Principals.personal_assistant(uid)

    assert %{"bindings" => [%{"agent_uid" => agent, "worker_token" => desktop_token}]} =
             bindings(desktop_session, 200)

    assert agent == assistant.uid

    assert %{"bindings" => [%{"worker_token" => notebook_token}]} =
             bindings(notebook_session, 200)

    assert {:ok, %{runner_id: id}} = RunnerDevices.authenticate(agent, desktop_token)
    assert id == desktop["id"]
    assert AgentWorkers.get_agent_worker!(agent).provider_id

    colleague = Ankole.SessionsCase.agent_fixture(%{owner_principal_uid: uid}).principal

    assert %{"bindings" => [_, _]} =
             member
             |> recycle_json()
             |> post(@devices <> "/" <> notebook["id"] <> "/bindings", %{
               data: %{agentUID: colleague.uid}
             })
             |> json_response(201)

    assert %{"bindings" => bindings} = bindings(notebook_session, 200)
    assert MapSet.new(Enum.map(bindings, & &1["agent_uid"])) == MapSet.new([agent, colleague.uid])

    assert %{"revoked" => true} =
             member
             |> recycle_json()
             |> delete(@devices <> "/" <> desktop["id"])
             |> json_response(200)

    assert %{"error" => %{"code" => "invalid_runner_credential"}} = bindings(desktop_session, 401)
    assert {:error, :invalid_worker_credential} = RunnerDevices.authenticate(agent, desktop_token)
    assert {:ok, %{runner_id: id}} = RunnerDevices.authenticate(agent, notebook_token)
    assert id == notebook["id"]
  end

  test "a conversation Job records the chosen Runner and deduplicates a retried submit", %{
    conn: conn
  } do
    {member, uid} = login_member(conn)
    runner = register(member, "Backtest")
    _session = pair(runner)
    assistant = Principals.personal_assistant(uid)
    fixture = Ankole.AIGatewayCase.background_agent_fixture()

    {:ok, _} =
      Ankole.AIGateway.ModelProfiles.put_model_profile(assistant.uid, "coding", %{
        provider_id: fixture.provider_id,
        model: "openai/gpt-5.6-sol"
      })

    {:ok, room} =
      Ankole.ConversationsFixtures.create(uid, %{
        conversation_id: Ash.UUIDv7.generate(),
        message_id: Ash.UUIDv7.generate(),
        agent_uid: assistant.uid,
        text: "Prepare the backtest."
      })

    path = "/api/v2/pod/conversations/#{room.conversation.id}/runner-jobs"

    attrs = %{
      agentUID: assistant.uid,
      runnerID: runner["id"],
      requestID: Ash.UUIDv7.generate(),
      title: "Run factor backtest",
      task: "Run the backtest on the workstation."
    }

    assert %{"jobID" => job_id} =
             member |> recycle_json() |> post(path, %{data: attrs}) |> json_response(201)

    assert %{"jobID" => ^job_id} =
             member |> recycle_json() |> post(path, %{data: attrs}) |> json_response(201)

    job = BackgroundAgentJobs.get_job(job_id)
    assert job.runner_id == runner["id"]
    assert job.human_uid == uid
    assert job.reply_route["conversation_id"] == room.conversation.id

    assert %{"errors" => [%{"code" => "runner_unavailable"}]} =
             member
             |> recycle_json()
             |> post(path, %{data: %{attrs | runnerID: Ash.UUIDv7.generate()}})
             |> json_response(409)
  end

  defp login_member(conn) do
    %{principal: member} = Ankole.PrincipalsFixtures.human_fixture(%{membership: :member})
    conn = conn |> Plug.Test.init_test_session(%{}) |> WebSession.ensure_browser()

    {:ok, %{browser: browser, authentication: auth}} =
      BrowserSessions.authenticate(WebSession.browser_reference(conn), %{
        "principal_uid" => member.uid,
        "access_version" => member.access_version,
        "provider_id" => "local",
        "external_id" => member.uid
      })

    conn =
      conn
      |> WebSession.put_authentication(browser, auth)
      |> with_console_csrf()
      |> get("/api/v2/browser/session")
      |> recycle_api()

    {conn, member.uid}
  end

  defp recycle_json(conn) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
  end

  defp register(conn, name) do
    conn |> recycle_json() |> post(@devices, %{data: %{name: name}}) |> json_response(201)
  end

  defp pair(device, status \\ 200) do
    # The site request clears the calling process's selected Pod context.
    tenant = Repo.tenant_id!()

    result =
      build_conn() |> post(@internal <> "/pair", %{code: device["code"]}) |> json_response(status)

    :ok = Repo.put_tenant_id(tenant)
    result
  end

  defp bindings(session, status) do
    tenant = Repo.tenant_id!()

    result =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> session["token"])
      |> get(@internal <> "/bindings")
      |> json_response(status)

    :ok = Repo.put_tenant_id(tenant)
    result
  end
end
