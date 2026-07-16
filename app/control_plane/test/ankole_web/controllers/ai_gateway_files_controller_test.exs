defmodule AnkoleWeb.AIGatewayFilesControllerTest do
  use AnkoleWeb.ConnCase, async: true

  import Ankole.PrincipalsFixtures

  alias AnkoleWeb.AIGatewayTokens

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
       )

  test "official Files API create/list/retrieve/content/delete contract", %{conn: conn} do
    agent = agent_fixture()
    assert {:ok, token} = AIGatewayTokens.mint_for_agent(agent.principal.uid)
    upload = upload_fixture("sdk-image.png", @png, "image/png")

    created_conn =
      conn
      |> authorize(token.api_key)
      |> post("/api/v1/ai-gateway/files", %{
        "file" => upload,
        "purpose" => "vision",
        "expires_after" => %{"anchor" => "created_at", "seconds" => 3_600}
      })

    file = json_response(created_conn, 200)
    assert file["id"] =~ ~r/^file_[0-9a-f-]{36}$/
    assert file["object"] == "file"
    assert file["bytes"] == byte_size(@png)
    assert file["filename"] == "sdk-image.png"
    assert file["purpose"] == "vision"
    assert file["status"] == "processed"
    assert is_integer(file["created_at"])
    assert file["expires_at"] >= file["created_at"] + 3_599

    listed_conn =
      build_conn()
      |> authorize(token.api_key)
      |> get("/api/v1/ai-gateway/files", %{"limit" => 1, "order" => "desc"})

    assert %{
             "object" => "list",
             "data" => [listed],
             "first_id" => file_id,
             "last_id" => file_id,
             "has_more" => false
           } = json_response(listed_conn, 200)

    assert listed["id"] == file["id"]

    retrieved_conn =
      build_conn()
      |> authorize(token.api_key)
      |> get("/api/v1/ai-gateway/files/#{file["id"]}")

    assert json_response(retrieved_conn, 200) == file

    content_conn =
      build_conn()
      |> authorize(token.api_key)
      |> get("/api/v1/ai-gateway/files/#{file["id"]}/content")

    assert response(content_conn, 200) == @png
    assert get_resp_header(content_conn, "content-type") == ["image/png"]

    deleted_conn =
      build_conn()
      |> authorize(token.api_key)
      |> delete("/api/v1/ai-gateway/files/#{file["id"]}")

    assert json_response(deleted_conn, 200) == %{
             "id" => file["id"],
             "object" => "file",
             "deleted" => true
           }

    missing_conn =
      build_conn()
      |> authorize(token.api_key)
      |> get("/api/v1/ai-gateway/files/#{file["id"]}")

    assert %{"error" => %{"type" => "invalid_request_error", "code" => "not_found"}} =
             json_response(missing_conn, 404)
  end

  test "files are indistinguishable from missing across subjects", %{conn: conn} do
    owner = agent_fixture()
    other = agent_fixture()
    assert {:ok, owner_token} = AIGatewayTokens.mint_for_agent(owner.principal.uid)
    assert {:ok, other_token} = AIGatewayTokens.mint_for_agent(other.principal.uid)

    created_conn =
      conn
      |> authorize(owner_token.api_key)
      |> post("/api/v1/ai-gateway/files", %{
        "file" => upload_fixture("private.png", @png, "image/png"),
        "purpose" => "vision"
      })

    file_id = json_response(created_conn, 200)["id"]

    for method <- [:get, :delete] do
      cross_subject =
        build_conn()
        |> authorize(other_token.api_key)
        |> dispatch(method, "/api/v1/ai-gateway/files/#{file_id}")

      assert %{"error" => %{"code" => "not_found"}} = json_response(cross_subject, 404)
    end
  end

  test "file validation enforces purpose, expiry, MIME sniffing, and the 50 MiB limit", %{
    conn: conn
  } do
    agent = agent_fixture()
    assert {:ok, token} = AIGatewayTokens.mint_for_agent(agent.principal.uid)

    for {params, expected_param, expected_code} <- [
          {%{
             "file" => upload_fixture("wrong-purpose.png", @png, "image/png"),
             "purpose" => "assistants"
           }, "purpose", "unsupported_value"},
          {%{
             "file" => upload_fixture("short-expiry.png", @png, "image/png"),
             "purpose" => "vision",
             "expires_after" => %{"anchor" => "created_at", "seconds" => 3_599}
           }, "expires_after.seconds", "invalid_value"},
          {%{
             "file" => upload_fixture("not-an-image.png", "plain text", "image/png"),
             "purpose" => "vision"
           }, "file", "invalid_image"},
          {%{
             "file" => sparse_upload_fixture("oversized.png", 50 * 1024 * 1024 + 1),
             "purpose" => "vision"
           }, "file", "request_too_large"}
        ] do
      response =
        conn
        |> recycle()
        |> authorize(token.api_key)
        |> post("/api/v1/ai-gateway/files", params)
        |> json_response(400)

      assert get_in(response, ["error", "param"]) == expected_param
      assert get_in(response, ["error", "code"]) == expected_code
    end
  end

  defp authorize(conn, api_key),
    do: put_req_header(conn, "authorization", "Bearer #{api_key}")

  defp dispatch(conn, :get, path), do: get(conn, path)
  defp dispatch(conn, :delete, path), do: delete(conn, path)

  defp upload_fixture(filename, bytes, content_type) do
    path =
      Path.join(System.tmp_dir!(), "ankole-#{System.unique_integer([:positive])}-#{filename}")

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    %Plug.Upload{path: path, filename: filename, content_type: content_type}
  end

  defp sparse_upload_fixture(filename, size) do
    path =
      Path.join(System.tmp_dir!(), "ankole-#{System.unique_integer([:positive])}-#{filename}")

    File.open!(path, [:write, :binary], fn file ->
      {:ok, _position} = :file.position(file, size - 1)
      :ok = IO.binwrite(file, <<0>>)
    end)

    on_exit(fn -> File.rm(path) end)
    %Plug.Upload{path: path, filename: filename, content_type: "image/png"}
  end
end
