defmodule AnkoleWeb.AgentFileControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import Ankole.FilesFixtures
  import Ankole.PrincipalsFixtures
  alias Ankole.{AuthZ, Files, Repo}
  alias Ankole.AuthZ.Grant

  test "site operators browse public, Human private, Agent private and conversation roots", %{
    conn: conn,
    tenant: tenant
  } do
    conn = console_conn(conn)
    %{principal: human} = human_fixture()
    %{principal: agent} = agent_fixture()
    signal = Ankole.SignalsFixtures.external_session_signal_fixture(agent.uid)

    {:ok, conversation} =
      Repo.transact(fn -> Files.ensure_conversation_root_in_tx(signal.conversation_id) end)

    {:ok, human_root} = Files.private_root(human.uid)
    {:ok, agent_root} = Files.private_root(agent.uid)
    {:ok, public} = Files.public_root()
    result = conn |> api_get("/api/v2/drive/#{tenant.id}/nodes") |> json_response(200)
    ids = MapSet.new(Enum.map(result["nodes"], & &1["id"]))

    assert Enum.all?(
             [public.id, human_root.id, agent_root.id, conversation.id],
             &MapSet.member?(ids, &1)
           )
  end

  test "same-name folder uploads create a distinct folder without a conflict", %{
    conn: conn,
    tenant: tenant
  } do
    conn = console_conn(conn)
    {:ok, root} = Files.public_root()

    ids =
      for _ <- 1..2 do
        response =
          conn
          |> recycle_api()
          |> api_post("/api/v2/drive/#{tenant.id}/nodes", %{
            parent_id: root.id,
            name: "reports",
            kind: "folder"
          })
          |> json_response(201)

        response["id"]
      end

    assert length(Enum.uniq(ids)) == 2

    assert Ankole.Files.Nodes.list_children(root.id)
           |> Enum.filter(&(&1.id in ids))
           |> Enum.map(& &1.name) == ["reports", "reports (1)"]
  end

  test "uploads and browses a different tenant while its Worker is offline", %{conn: conn} do
    conn = console_conn(conn)
    other = Ankole.DataCase.create_tenant()

    {agent, root} =
      Repo.with_tenant(other.id, fn ->
        %{principal: agent} = agent_fixture()
        {:ok, root} = Files.private_root(agent.uid)
        {agent, root}
      end)

    uploaded =
      conn
      |> recycle_api()
      |> multipart("/api/v2/drive/#{other.id}/uploads",
        parent_id: root.id,
        name: "brief.txt",
        file: build_upload!("brief")
      )
      |> json_response(200)

    assert %{
             "uploaded_file" => %{
               "id" => id,
               "object_id" => object_id,
               "size" => 5,
               "name" => "brief.txt"
             }
           } = uploaded

    assert is_binary(object_id)

    assert conn
           |> recycle_api()
           |> get("/api/v2/drive/#{other.id}/nodes/#{id}/content")
           |> response(200) == "brief"

    assert %{"nodes" => [%{"id" => ^id, "size" => 5}], "ancestors" => [%{"id" => root_id}]} =
             conn
             |> recycle_api()
             |> api_get("/api/v2/drive/#{other.id}/nodes?parent_id=#{root.id}")
             |> json_response(200)

    assert root_id == root.id

    assert Repo.with_tenant(other.id, fn ->
             {:ok, _, bytes} = Files.read(agent.uid, "brief.txt")
             bytes
           end) == "brief"
  end

  test "owner filtering accepts named Principal IDs", %{conn: conn, tenant: tenant} do
    conn = console_conn(conn)
    %{principal: agent} = agent_fixture(%{uid: "ops+team@example.com"})
    {:ok, root} = Files.private_root(agent.uid)
    query = URI.encode_query(%{"owner_uid" => agent.uid})

    assert %{"nodes" => [%{"id" => root_id}]} =
             conn
             |> recycle_api()
             |> api_get("/api/v2/drive/#{tenant.id}/nodes?#{query}")
             |> json_response(200)

    assert root_id == root.id
  end

  test "nested Console breadcrumbs contain each node name in root-to-leaf order", %{
    conn: conn,
    tenant: tenant
  } do
    conn = console_conn(conn)
    %{principal: agent} = agent_fixture()
    drive_file_fixture(agent.uid, "projects/releases/notes.txt", "notes")
    {:ok, root} = Files.private_root(agent.uid)
    [projects] = Ankole.Files.Nodes.list_children(root.id)
    [releases] = Ankole.Files.Nodes.list_children(projects.id)

    result =
      conn
      |> api_get("/api/v2/drive/#{tenant.id}/nodes?parent_id=#{releases.id}")
      |> json_response(200)

    assert result["ancestors"] == [
             %{"id" => root.id, "name" => root.name},
             %{"id" => projects.id, "name" => "projects"},
             %{"id" => releases.id, "name" => "releases"}
           ]
  end

  @tag timeout: 120_000
  test "streaming backend multipart uploads exceed the old 128 MiB parser ceiling", %{
    conn: conn,
    tenant: tenant
  } do
    conn = console_conn(conn)
    %{principal: agent} = agent_fixture()
    {:ok, root} = Files.private_root(agent.uid)
    size = 128 * 1024 * 1024 + 1
    upload = build_upload!(<<>>)
    {:ok, io} = File.open(upload.path, [:write, :binary])
    {:ok, _} = :file.position(io, size - 1)
    :ok = IO.binwrite(io, "Z")
    :ok = File.close(io)

    assert %{"uploaded_file" => %{"id" => id, "size" => ^size}} =
             conn
             |> recycle_api()
             |> multipart("/api/v2/drive/#{tenant.id}/uploads",
               parent_id: root.id,
               name: "large.bin",
               file: upload
             )
             |> json_response(200)

    download =
      conn
      |> recycle_api()
      |> put_req_header("range", "bytes=-1")
      |> get("/api/v2/drive/#{tenant.id}/nodes/#{id}/content")

    assert response(download, 206) == "Z"
    assert get_resp_header(download, "content-range") == ["bytes #{size - 1}-#{size - 1}/#{size}"]
  end

  test "node IDs survive moves and deleting a folder hides its subtree", %{
    conn: conn,
    tenant: tenant
  } do
    conn = console_conn(conn)
    %{principal: agent} = agent_fixture()
    file = drive_file_fixture(agent.uid, "drafts/a.md", "A")
    {:ok, root} = Files.private_root(agent.uid)

    assert %{"id" => folder_id} =
             conn
             |> recycle_api()
             |> api_post("/api/v2/drive/#{tenant.id}/nodes", %{
               parent_id: root.id,
               name: "final",
               kind: "folder"
             })
             |> json_response(201)

    assert %{"id" => id} =
             conn
             |> recycle_api()
             |> api_patch("/api/v2/drive/#{tenant.id}/nodes/#{file.id}", %{
               parent_id: folder_id,
               name: "renamed.md"
             })
             |> json_response(200)

    assert id == file.id
    assert {:ok, %{id: ^id}, "A"} = Files.read(agent.uid, "final/renamed.md")

    assert %{"id" => ^folder_id} =
             conn
             |> recycle_api()
             |> api_delete("/api/v2/drive/#{tenant.id}/nodes/#{folder_id}")
             |> json_response(200)

    assert {:error, :not_found} = Files.read(agent.uid, "final/renamed.md")

    assert conn
           |> recycle_api()
           |> get("/api/v2/drive/#{tenant.id}/nodes/#{id}/content")
           |> response(404)
  end

  test "pagination uses stable names and collision uploads get new nodes", %{
    conn: conn,
    tenant: tenant
  } do
    conn = console_conn(conn)
    %{principal: agent} = agent_fixture()
    {:ok, root} = Files.private_root(agent.uid)

    for name <- ["b.txt", "a.txt", "a.txt"] do
      assert conn
             |> recycle_api()
             |> multipart("/api/v2/drive/#{tenant.id}/uploads",
               parent_id: root.id,
               name: name,
               file: build_upload!(name)
             )
             |> json_response(200)
    end

    url = "/api/v2/drive/#{tenant.id}/nodes?parent_id=#{root.id}&limit=2"

    assert %{"nodes" => first, "next_after" => cursor} =
             conn |> recycle_api() |> api_get(url) |> json_response(200)

    assert length(first) == 2
    assert is_binary(cursor)

    assert %{"nodes" => [last], "next_after" => nil} =
             conn
             |> recycle_api()
             |> api_get(url <> "&after=" <> URI.encode_www_form(cursor))
             |> json_response(200)

    assert Enum.uniq_by(first ++ [last], & &1["id"]) == first ++ [last]
    assert Enum.uniq_by(first ++ [last], & &1["name"]) == first ++ [last]
  end

  test "site_console drive permission and CEL apply across all spaces", %{
    conn: conn,
    tenant: tenant
  } do
    {conn, admin_uid} = console_conn_with_principal(conn)
    %{principal: agent} = agent_fixture()
    file = drive_file_fixture(agent.uid, "notes.txt", "notes")
    {:ok, root} = Files.private_root(agent.uid)

    Repo.delete_all(
      from grant in Grant,
        where: grant.resource_pattern in ["site_console:**", "tenant_console:**"]
    )

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: admin_uid,
        resource_pattern: "site_console:drive",
        action: "read",
        condition: "true",
        metadata: %{}
      })

    {:ok, _} =
      AuthZ.create_permission_grant(%{
        principal_uid: admin_uid,
        resource_pattern: "site_console:drive",
        action: "update",
        condition: "false",
        metadata: %{}
      })

    assert conn
           |> recycle_api()
           |> api_get("/api/v2/drive/#{tenant.id}/nodes")
           |> json_response(200)

    assert conn
           |> recycle_api()
           |> get("/api/v2/drive/#{tenant.id}/nodes/#{file.id}/content")
           |> response(200) == "notes"

    assert conn
           |> recycle_api()
           |> multipart("/api/v2/drive/#{tenant.id}/uploads",
             parent_id: root.id,
             name: "denied.txt",
             file: build_upload!("denied")
           )
           |> json_response(403)

    assert conn
           |> recycle_api()
           |> api_delete("/api/v2/drive/#{tenant.id}/nodes/#{file.id}")
           |> json_response(403)

    assert {:ok, _, "notes"} = Files.read(agent.uid, "notes.txt")
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
    |> post(path, IO.iodata_to_binary(body))
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
  defp api_patch(conn, path, body), do: api_request(conn, :patch, path, body)
end
