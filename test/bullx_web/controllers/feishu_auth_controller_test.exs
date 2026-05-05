defmodule BullXWeb.FeishuAuthControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullXAccounts.{User, UserChannelBinding}

  @callback_url "http://localhost:4000/sessions/default/callback"

  setup do
    previous_gateway = Application.get_env(:bullx, :gateway)

    client =
      FeishuOpenAPI.new("cli_test", "secret_test", req_options: [plug: {Req.Test, __MODULE__}])

    Application.put_env(:bullx, :gateway,
      adapters: [
        {{:feishu, "default"}, BullXFeishu.Adapter, feishu_gateway_config(client)}
      ]
    )

    on_exit(fn ->
      case previous_gateway do
        nil -> Application.delete_env(:bullx, :gateway)
        value -> Application.put_env(:bullx, :gateway, value)
      end
    end)

    {:ok, client: client}
  end

  test "GET /sessions/:channel_id redirects to Feishu authorization URL and stores cookie state",
       %{conn: conn} do
    conn = %{conn | scheme: :http, host: "internal-host", port: 4000}
    conn = get(conn, ~p"/sessions/default?return_to=/")

    redirect = redirected_to(conn, 302)
    query = auth_redirect_query(redirect)

    assert redirect =~ "https://accounts.feishu.cn/open-apis/authen/v1/authorize"
    assert query["client_id"] == "cli_test"
    assert query["redirect_uri"] == @callback_url
    assert query["response_type"] == "code"
    assert is_binary(query["state"])

    assert %{
             "provider" => "feishu",
             "channel_id" => "default",
             "return_to" => "/",
             "nonce" => nonce
           } = get_session(conn, :session_controller_state)

    assert nonce == query["state"]
  end

  test "GET /sessions/:channel_id refuses provider login when channel disables web login", %{
    conn: conn,
    client: client
  } do
    Application.put_env(:bullx, :gateway,
      adapters: [
        {{:feishu, "default"}, BullXFeishu.Adapter,
         feishu_gateway_config(client, %{web_login_disabled: true})}
      ]
    )

    conn = get(conn, ~p"/sessions/default?return_to=/")

    assert redirected_to(conn) == ~p"/sessions/new"
    assert get_session(conn, :session_controller_state) == nil
  end

  test "SSO callback refuses login when channel disables web login", %{client: client} do
    Application.put_env(:bullx, :gateway,
      adapters: [
        {{:feishu, "default"}, BullXFeishu.Adapter,
         feishu_gateway_config(client, %{web_login_disabled: true})}
      ]
    )

    assert {:error, :web_login_disabled} =
             BullXFeishu.SSO.login_from_callback(%{
               "channel_id" => "default",
               "redirect_uri" => @callback_url,
               "code" => "CODE"
             })
  end

  test "callback logs in a bound Feishu user and discards provider tokens", %{conn: conn} do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "default", external_id: "feishu:ou_user")

    state = "STATE"
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/authen/v2/oauth/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:token_body, Jason.decode!(body)})

          Req.Test.json(conn, %{
            "code" => 0,
            "access_token" => "u-token",
            "refresh_token" => "r-token",
            "token_type" => "Bearer",
            "expires_in" => 7200
          })

        "/open-apis/authen/v1/user_info" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer u-token"]

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{"open_id" => "ou_user", "name" => "Alice"}
          })
      end
    end)

    conn =
      conn
      |> init_test_session(%{
        session_controller_state: %{
          "provider" => "feishu",
          "channel_id" => "default",
          "return_to" => "/",
          "nonce" => state,
          "issued_at" => System.system_time(:second)
        }
      })
      |> get(~p"/sessions/default/callback?code=CODE&state=#{state}")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :session_controller_state) == nil

    assert_received {:token_body,
                     %{
                       "grant_type" => "authorization_code",
                       "client_id" => "cli_test",
                       "client_secret" => "secret_test",
                       "code" => "CODE",
                       "redirect_uri" => @callback_url
                     }}
  end

  test "callback rejects mismatched cookie state", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{
        session_controller_state: %{
          "provider" => "feishu",
          "channel_id" => "other",
          "return_to" => "/",
          "nonce" => "STATE",
          "issued_at" => System.system_time(:second)
        }
      })
      |> get(~p"/sessions/default/callback?code=CODE&state=STATE")

    assert redirected_to(conn) == ~p"/sessions/new"
    assert get_session(conn, :user_id) == nil
  end

  defp insert_user!(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert!()
  end

  defp insert_binding!(user, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put(:user_id, user.id)
      |> Map.put_new(:metadata, %{})

    %UserChannelBinding{}
    |> UserChannelBinding.changeset(attrs)
    |> Repo.insert!()
  end

  defp feishu_gateway_config(client, attrs \\ %{}) do
    Map.merge(
      %{
        app_id: "cli_test",
        app_secret: "secret_test",
        client: client
      },
      attrs
    )
  end

  defp auth_redirect_query(url) do
    url
    |> URI.parse()
    |> Map.fetch!(:query)
    |> URI.decode_query()
  end
end
