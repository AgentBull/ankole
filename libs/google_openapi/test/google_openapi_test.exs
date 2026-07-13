defmodule GoogleOpenAPITest do
  use ExUnit.Case, async: true

  alias GoogleOpenAPI.Auth
  alias GoogleOpenAPI.Client
  alias GoogleOpenAPI.Directory
  alias GoogleOpenAPI.Error

  defp client(overrides \\ []) do
    Client.new(
      Keyword.merge(
        [
          client_id: "client-1",
          client_secret: "secret-1",
          service_account_email: "sa-#{System.unique_integer([:positive])}@proj.iam.test",
          delegated_subject: "admin@example.com",
          assertion_signer: fn claims -> {:ok, "assertion-for-#{claims["iss"]}"} end,
          auth_base_url: "https://accounts.google.test",
          token_base_url: "https://oauth2.google.test",
          userinfo_base_url: "https://openidconnect.google.test",
          api_base_url: "https://admin.google.test",
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

  test "authorize_url builds the Google OAuth URL with the hosted-domain hint" do
    url =
      Auth.authorize_url(
        auth_base_url: "https://accounts.google.test",
        client_id: "client-1",
        redirect_uri: "https://ankole.test/sessions/oidc/google-workspace-main/callback",
        state: "state-1",
        scopes: ["openid", "email", "profile"],
        hd: "example.com"
      )

    uri = URI.parse(url)
    assert uri.host == "accounts.google.test"
    assert uri.path == "/o/oauth2/v2/auth"

    query = URI.decode_query(uri.query)
    assert query["client_id"] == "client-1"
    assert query["response_type"] == "code"
    assert query["scope"] == "openid email profile"
    assert query["state"] == "state-1"
    assert query["hd"] == "example.com"
  end

  test "exchange_code posts the authorization-code grant" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/token"
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
             Auth.exchange_code(client(),
               code: "code-1",
               redirect_uri: "https://ankole.test/callback"
             )
  end

  test "userinfo fetches claims with the delegated bearer" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/userinfo"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer at-userinfo"]

      Req.Test.json(conn, %{
        "sub" => "103200300400500600700",
        "email" => "alice@example.com",
        "email_verified" => true,
        "hd" => "example.com"
      })
    end)

    assert {:ok, %{"sub" => "103200300400500600700", "hd" => "example.com"}} =
             Auth.userinfo(client(), "at-userinfo")
  end

  test "jwt_bearer_token signs the grant claims and caches per scope and subject" do
    parent = self()

    client =
      client(
        assertion_signer: fn claims ->
          send(parent, {:assertion_claims, claims})
          {:ok, "signed-assertion"}
        end
      )

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      form = URI.decode_query(body)

      assert form["grant_type"] == "urn:ietf:params:oauth:grant-type:jwt-bearer"
      assert form["assertion"] == "signed-assertion"
      send(parent, :token_request)

      Req.Test.json(conn, %{"access_token" => "sa-token", "expires_in" => 3600})
    end)

    assert {:ok, "sa-token"} = Auth.jwt_bearer_token(client, scope: ["scope-a", "scope-b"])
    assert {:ok, "sa-token"} = Auth.jwt_bearer_token(client, scope: ["scope-a", "scope-b"])

    assert_received :token_request
    refute_received :token_request

    assert_received {:assertion_claims, claims}
    assert claims["iss"] == client.service_account_email
    assert claims["sub"] == "admin@example.com"
    assert claims["scope"] == "scope-a scope-b"
    assert claims["aud"] == "https://oauth2.google.test/token"
    assert claims["exp"] - claims["iat"] == 3600
  end

  test "jwt_bearer_token surfaces signer failures without calling the endpoint" do
    client = client(assertion_signer: fn _claims -> {:error, :kernel_unavailable} end)

    assert {:error, %Error{reason: :assertion_signing_failed}} =
             Auth.jwt_bearer_token(client, scope: "scope-fail")
  end

  test "directory list requests mint a bearer and cap the page size" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/token"} = conn ->
        Req.Test.json(conn, %{"access_token" => "dir-token", "expires_in" => 3600})

      conn ->
        assert conn.request_path == "/admin/directory/v1/users"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer dir-token"]
        query = URI.decode_query(conn.query_string)
        assert query["customer"] == "my_customer"
        assert query["maxResults"] == "500"
        Req.Test.json(conn, %{"users" => [%{"id" => "1"}]})
    end)

    assert {:ok, %{"users" => [%{"id" => "1"}]}} =
             Directory.list_users(client(), customer: "my_customer", maxResults: 9999)
  end

  test "stream_users follows nextPageToken and retries rate limits" do
    parent = self()

    {:ok, page_counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(__MODULE__, fn
      %{request_path: "/token"} = conn ->
        Req.Test.json(conn, %{"access_token" => "dir-token", "expires_in" => 3600})

      conn ->
        assert conn.request_path == "/admin/directory/v1/users"
        page = Agent.get_and_update(page_counter, fn count -> {count, count + 1} end)
        query = URI.decode_query(conn.query_string)
        send(parent, {:page_request, page, query["pageToken"]})

        case page do
          0 ->
            Req.Test.json(conn, %{"users" => [%{"id" => "1"}], "nextPageToken" => "page-2"})

          1 ->
            conn
            |> Plug.Conn.put_resp_header("retry-after", "0")
            |> Plug.Conn.send_resp(429, "")

          _rest ->
            Req.Test.json(conn, %{"users" => [%{"id" => "2"}, %{"id" => "3"}]})
        end
    end)

    results = client() |> Directory.stream_users(customer: "my_customer") |> Enum.to_list()

    assert [{:ok, %{"id" => "1"}}, {:ok, %{"id" => "2"}}, {:ok, %{"id" => "3"}}] = results
    assert_received {:page_request, 0, nil}
    assert_received {:page_request, 1, "page-2"}
    assert_received {:page_request, 2, "page-2"}
  end

  test "stream_members emits the error tuple for non-retryable failures" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/token"} = conn ->
        Req.Test.json(conn, %{"access_token" => "dir-token", "expires_in" => 3600})

      conn ->
        assert conn.request_path == "/admin/directory/v1/groups/group%40example.com/members" or
                 conn.request_path == "/admin/directory/v1/groups/group@example.com/members"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          404,
          ~s({"error":{"code":404,"status":"NOT_FOUND","errors":[{"reason":"notFound"}]}})
        )
    end)

    assert [{:error, %Error{reason: "notFound", status: 404}}] =
             client() |> Directory.stream_members("group@example.com") |> Enum.to_list()
  end

  test "403 rate-limit reasons classify as rate_limited and other 403s keep their reason" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/token"} = conn ->
        Req.Test.json(conn, %{"access_token" => "dir-token", "expires_in" => 3600})

      conn ->
        body =
          case URI.decode_query(conn.query_string)["case"] do
            "quota" -> ~s({"error":{"code":403,"errors":[{"reason":"quotaExceeded"}]}})
            _other -> ~s({"error":{"code":403,"errors":[{"reason":"forbidden"}]}})
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(403, body)
    end)

    assert {:error, %Error{reason: :rate_limited, status: 403}} =
             Directory.list_users(client(), case: "quota")

    assert {:error, %Error{reason: "forbidden", status: 403}} =
             Directory.list_users(client(), case: "forbidden")
  end

  test "jwt_bearer_token without a signer fails closed" do
    client = client(assertion_signer: nil, service_account_email: "unsigned@proj.iam.test")

    assert {:error, %Error{reason: :missing_assertion_signer}} =
             Auth.jwt_bearer_token(client, scope: "scope-x")
  end
end
