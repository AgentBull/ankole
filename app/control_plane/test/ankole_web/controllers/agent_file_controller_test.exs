defmodule AnkoleWeb.AgentFileControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.Files
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    %{principal: agent} = agent_fixture()
    %{agent_uid: agent.uid}
  end

  test "lists the folders and files of one folder", %{conn: conn, agent_uid: agent_uid} do
    conn = console_conn(conn)

    drive_file_fixture(agent_uid, "reports/q3.md", "Q3")
    drive_file_fixture(agent_uid, "reports/archive/q2.md", "Q2")
    drive_file_fixture(agent_uid, "notes.txt", "notes")

    assert %{"file_listing" => root} =
             conn
             |> recycle_api()
             |> api_get(~p"/api/v2/agents/#{agent_uid}/files")
             |> json_response(200)

    assert root["folders"] == [%{"name" => "reports", "path" => "reports"}]
    assert [%{"path" => "notes.txt", "size" => 5, "source" => "agent"}] = root["files"]

    assert %{"file_listing" => reports} =
             conn
             |> recycle_api()
             |> api_get(~p"/api/v2/agents/#{agent_uid}/files?path=reports")
             |> json_response(200)

    assert reports["folders"] == [%{"name" => "archive", "path" => "reports/archive"}]
    assert [%{"path" => "reports/q3.md", "content_type" => "text/markdown"}] = reports["files"]
  end

  test "lists projected origins and keeps them after a move", %{conn: conn, agent_uid: agent_uid} do
    conn = console_conn(conn)
    signal = Ankole.SignalsFixtures.external_session_signal_fixture(agent_uid)
    conversation_id = signal.conversation_id
    message_id = signal.message_id
    {:ok, %{sha256: sha256}} = Files.store("received")

    assert {:ok, _} =
             Files.commit(agent_uid, [
               %{
                 path: "inbox/attachment.txt",
                 sha256: sha256,
                 source: "inbound",
                 conversation_id: conversation_id,
                 message_id: message_id
               }
             ])

    assert %{"moved_files" => 1} =
             conn
             |> recycle_api()
             |> api_post(~p"/api/v2/agents/#{agent_uid}/file-moves", %{
               from_path: "inbox/attachment.txt",
               to_path: "kept/attachment.txt"
             })
             |> json_response(201)

    assert %{
             "file_listing" => %{
               "files" => [
                 %{
                   "path" => "kept/attachment.txt",
                   "conversation_id" => ^conversation_id,
                   "message_id" => ^message_id
                 }
               ]
             }
           } =
             conn
             |> recycle_api()
             |> api_get(~p"/api/v2/agents/#{agent_uid}/files?path=kept")
             |> json_response(200)
  end

  test "answers 404 for an Agent that does not exist", %{conn: conn} do
    conn = console_conn(conn)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> recycle_api()
             |> api_get(~p"/api/v2/agents/agent-missing/files")
             |> json_response(404)
  end

  test "uploads a file and downloads it again without a Worker", %{
    conn: conn,
    agent_uid: agent_uid
  } do
    conn = console_conn(conn)

    assert %{
             "uploaded_file" => %{"path" => "inbox/brief.txt", "size" => 5, "source" => "console"}
           } =
             conn
             |> recycle_api()
             |> multipart(~p"/api/v1/agents/#{agent_uid}/files",
               path: "inbox/brief.txt",
               file: build_upload!("brief")
             )
             |> json_response(200)

    download =
      conn
      |> recycle_api()
      |> api_get(~p"/api/v1/agents/#{agent_uid}/files/content?path=inbox/brief.txt")

    assert response(download, 200) == "brief"
    assert [disposition] = get_resp_header(download, "content-disposition")
    assert disposition =~ "brief.txt"

    assert %{"error" => %{"code" => "not_found"}} =
             conn
             |> recycle_api()
             |> api_get(~p"/api/v1/agents/#{agent_uid}/files/content?path=inbox/missing.txt")
             |> json_response(404)
  end

  test "rejects an upload over the transfer limit", %{conn: conn, agent_uid: agent_uid} do
    conn = console_conn(conn)

    oversize = :binary.copy(<<0>>, Ankole.WorkerFiles.max_transfer_bytes() + 1)

    assert %{"error" => %{"code" => "file_too_large"}} =
             conn
             |> recycle_api()
             |> multipart(~p"/api/v1/agents/#{agent_uid}/files",
               path: "huge.bin",
               file: build_upload!(oversize)
             )
             |> json_response(422)

    assert {:ok, %{files: []}} = Files.list(agent_uid)
  end

  test "rejects uploads and moves that make one path both a file and a folder", %{
    conn: conn,
    agent_uid: agent_uid
  } do
    conn = console_conn(conn)
    drive_file_fixture(agent_uid, "existing", "kept")
    drive_file_fixture(agent_uid, "from/value.txt", "moved")

    assert %{"error" => %{"code" => "path_conflict"}} =
             conn
             |> recycle_api()
             |> multipart(~p"/api/v1/agents/#{agent_uid}/files",
               path: "existing/child.txt",
               file: build_upload!("rejected")
             )
             |> json_response(409)

    assert %{"errors" => [%{"code" => "path_conflict"}]} =
             conn
             |> recycle_api()
             |> api_post(~p"/api/v2/agents/#{agent_uid}/file-moves", %{
               from_path: "from",
               to_path: "existing"
             })
             |> json_response(409)

    assert {:ok, _file, "kept"} = Files.read(agent_uid, "existing")
    assert {:ok, _file, "moved"} = Files.read(agent_uid, "from/value.txt")
    assert {:error, :not_found} = Files.fetch(agent_uid, "existing/child.txt")
  end

  test "moves a folder and deletes it", %{conn: conn, agent_uid: agent_uid} do
    conn = console_conn(conn)

    drive_file_fixture(agent_uid, "drafts/a.md", "a")
    drive_file_fixture(agent_uid, "drafts/b.md", "b")

    assert %{"moved_files" => 2} =
             conn
             |> recycle_api()
             |> api_post(~p"/api/v2/agents/#{agent_uid}/file-moves", %{
               from_path: "drafts",
               to_path: "final"
             })
             |> json_response(201)

    assert {:ok, %{files: files}} = Files.list(agent_uid)
    assert Enum.map(files, & &1.path) == ["final/a.md", "final/b.md"]

    assert %{"deleted_files" => 2} =
             conn
             |> recycle_api()
             |> api_delete(~p"/api/v2/agents/#{agent_uid}/files?path=final")
             |> json_response(200)

    assert {:ok, %{files: []}} = Files.list(agent_uid)
  end

  test "requires the Agent's files permission", %{conn: conn, agent_uid: agent_uid} do
    %{principal: other_agent} = agent_fixture()
    {conn, admin_uid} = console_conn_with_principal(conn)
    Repo.delete_all(from grant in Grant, where: grant.resource_pattern == "**")

    assert {:ok, _grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: admin_uid,
               resource_pattern: "agent:#{other_agent.uid}:files",
               action: "read",
               condition: "true",
               metadata: %{}
             })

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             conn
             |> recycle_api()
             |> api_get(~p"/api/v2/agents/#{agent_uid}/files")
             |> json_response(403)

    assert conn
           |> recycle_api()
           |> api_get(~p"/api/v2/agents/#{other_agent.uid}/files")
           |> json_response(200)
  end

  defp build_upload!(content) do
    path = Path.join(System.tmp_dir!(), "ankole-upload-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{
      filename: Path.basename(path),
      path: path,
      content_type: "application/octet-stream"
    }
  end

  defp multipart(conn, path, fields) do
    boundary = "ankole-test-boundary"

    body =
      Enum.map(fields, fn
        {:file, %Plug.Upload{path: file_path, filename: filename}} ->
          [
            "--#{boundary}\r\n",
            "content-disposition: form-data; name=\"file\"; filename=\"#{filename}\"\r\n",
            "content-type: application/octet-stream\r\n\r\n",
            File.read!(file_path),
            "\r\n"
          ]

        {name, value} ->
          [
            "--#{boundary}\r\n",
            "content-disposition: form-data; name=\"#{name}\"\r\n\r\n",
            to_string(value),
            "\r\n"
          ]
      end) ++ ["--#{boundary}--\r\n"]

    conn
    |> put_req_header("content-type", "multipart/form-data; boundary=#{boundary}")
    |> api_post(path, IO.iodata_to_binary(body))
  end

  defp api_request(conn, method, path, body \\ nil) do
    if String.starts_with?(path, "/api/v2/") do
      body =
        case body do
          nil ->
            nil

          value when is_binary(value) ->
            value

          value ->
            Jason.encode!(
              if Map.has_key?(value, :data) or Map.has_key?(value, "data"),
                do: value,
                else: %{data: value}
            )
        end

      conn
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> dispatch(@endpoint, method, path, body)
    else
      conn |> dispatch(@endpoint, method, path, body)
    end
  end

  defp api_get(conn, path), do: api_request(conn, :get, path)
  defp api_post(conn, path, body), do: api_request(conn, :post, path, body)
  defp api_delete(conn, path), do: api_request(conn, :delete, path)
end
