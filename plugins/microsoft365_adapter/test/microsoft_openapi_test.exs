defmodule MicrosoftOpenAPITest do
  use ExUnit.Case, async: true

  alias MicrosoftOpenAPI.Client
  alias MicrosoftOpenAPI.EntraAuth
  alias MicrosoftOpenAPI.Error
  alias MicrosoftOpenAPI.Graph
  alias MicrosoftOpenAPI.Pagination

  defp client(overrides \\ []) do
    Client.new(
      Keyword.merge(
        [
          tenant_id: "tenant-1",
          client_id: "client-1",
          client_secret: "secret-1",
          login_base_url: "https://login.microsoft.test",
          graph_base_url: "https://graph.microsoft.test",
          req_options: [plug: {Req.Test, __MODULE__}]
        ],
        overrides
      )
    )
  end

  test "client redacts the secret and resolves closures" do
    client = client()

    assert Client.client_secret(client) == "secret-1"
    refute inspect(client) =~ "secret-1"
  end

  test "authorize_url builds the Entra v2.0 authorization URL" do
    url =
      EntraAuth.authorize_url(
        login_base_url: "https://login.microsoft.test",
        tenant: "tenant-1",
        client_id: "client-1",
        redirect_uri: "https://ankole.test/sessions/oidc/entra-id-main/callback",
        state: "state-1",
        scopes: ["openid", "profile", "User.Read"]
      )

    uri = URI.parse(url)
    assert uri.host == "login.microsoft.test"
    assert uri.path == "/tenant-1/oauth2/v2.0/authorize"

    query = URI.decode_query(uri.query)
    assert query["client_id"] == "client-1"
    assert query["response_type"] == "code"
    assert query["scope"] == "openid profile User.Read"
    assert query["state"] == "state-1"
  end

  test "exchange_code posts the authorization-code grant" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/tenant-1/oauth2/v2.0/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)

      assert form["grant_type"] == "authorization_code"
      assert form["code"] == "code-1"
      assert form["client_secret"] == "secret-1"

      Req.Test.json(conn, %{
        "access_token" => "at-1",
        "id_token" => "idt-1",
        "expires_in" => 3599
      })
    end)

    assert {:ok, %{access_token: "at-1", id_token: "idt-1"}} =
             EntraAuth.exchange_code(client(),
               code: "code-1",
               redirect_uri: "https://ankole.test/callback"
             )
  end

  test "client_credentials_token caches per scope and tenant" do
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)
      send(parent, {:token_request, conn.request_path, form["scope"]})
      Req.Test.json(conn, %{"access_token" => "cc-#{form["scope"]}", "expires_in" => 3600})
    end)

    client = client(tenant_id: "tenant-cc-#{System.unique_integer([:positive])}")

    assert {:ok, token} = EntraAuth.client_credentials_token(client, scope: "scope-a")
    assert {:ok, ^token} = EntraAuth.client_credentials_token(client, scope: "scope-a")
    assert {:ok, other} = EntraAuth.client_credentials_token(client, scope: "scope-b")
    refute other == token

    assert_received {:token_request, _path, "scope-a"}
    assert_received {:token_request, _path, "scope-b"}
    refute_received {:token_request, _path, "scope-a"}
  end

  test "graph requests acquire a token and decode plain JSON" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/tenant-graph/oauth2/v2.0/token"} = conn ->
        Req.Test.json(conn, %{"access_token" => "graph-token", "expires_in" => 3600})

      conn ->
        assert conn.request_path == "/v1.0/users"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer graph-token"]
        assert conn.query_string =~ "%24top=2"
        Req.Test.json(conn, %{"value" => [%{"id" => "u1"}]})
    end)

    assert {:ok, %{"value" => [%{"id" => "u1"}]}} =
             Graph.get(client(tenant_id: "tenant-graph"), "users", query: [{"$top", 2}])
  end

  test "graph delegated token bypasses client credentials" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1.0/me"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer delegated-1"]
      Req.Test.json(conn, %{"id" => "user-1", "displayName" => "User One"})
    end)

    assert {:ok, %{"id" => "user-1"}} =
             Graph.get(client(), "me", token: {:bearer, "delegated-1"})
  end

  test "graph errors carry the error code and 429 keeps retry-after" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/tenant-err/oauth2/v2.0/token"} = conn ->
        Req.Test.json(conn, %{"access_token" => "t", "expires_in" => 3600})

      %{request_path: "/v1.0/forbidden"} = conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => %{"code" => "Authorization_RequestDenied"}})

      %{request_path: "/v1.0/throttled"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "17")
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => %{"code" => "TooManyRequests"}})
    end)

    client = client(tenant_id: "tenant-err")

    assert {:error, %Error{reason: "Authorization_RequestDenied", status: 403} = error} =
             Graph.get(client, "forbidden")

    refute Error.retryable?(error)

    assert {:error, %Error{reason: :rate_limited, retry_after: 17} = throttled} =
             Graph.get(client, "throttled")

    assert Error.retryable?(throttled)
  end

  test "pagination follows @odata.nextLink and stops" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/tenant-page/oauth2/v2.0/token"} = conn ->
        Req.Test.json(conn, %{"access_token" => "t", "expires_in" => 3600})

      %{request_path: "/v1.0/users"} = conn ->
        Req.Test.json(conn, %{
          "value" => [%{"id" => "u1"}, %{"id" => "u2"}],
          "@odata.nextLink" => "https://graph.microsoft.test/v1.0/users-page-2"
        })

      %{request_path: "/v1.0/users-page-2"} = conn ->
        assert conn.query_string == ""
        Req.Test.json(conn, %{"value" => [%{"id" => "u3"}]})
    end)

    results =
      Pagination.stream(client(tenant_id: "tenant-page"), "users", query: [{"$top", 2}])
      |> Enum.to_list()

    assert [{:ok, %{"id" => "u1"}}, {:ok, %{"id" => "u2"}}, {:ok, %{"id" => "u3"}}] = results
  end

  test "pagination surfaces terminal errors as one error element" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/tenant-pgerr/oauth2/v2.0/token"} = conn ->
        Req.Test.json(conn, %{"access_token" => "t", "expires_in" => 3600})

      conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"error" => %{"code" => "Authorization_RequestDenied"}})
    end)

    assert [{:error, %Error{reason: "Authorization_RequestDenied"}}] =
             Pagination.stream(client(tenant_id: "tenant-pgerr"), "users") |> Enum.to_list()
  end
end
