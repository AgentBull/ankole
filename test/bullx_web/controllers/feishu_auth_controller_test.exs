defmodule BullXWeb.FeishuAuthControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullXAccounts.{User, UserChannelBinding}

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

  test "GET /sessions/feishu redirects to Feishu authorization URL", %{conn: conn} do
    conn = get(conn, ~p"/sessions/feishu?channel_id=default&return_to=/")

    assert redirected_to(conn, 302) =~ "https://accounts.feishu.cn/open-apis/authen/v1/index"
    assert redirected_to(conn, 302) =~ "app_id=cli_test"
  end

  test "GET /sessions/feishu refuses provider login when channel disables web login", %{
    conn: conn,
    client: client
  } do
    Application.put_env(:bullx, :gateway,
      adapters: [
        {{:feishu, "default"}, BullXFeishu.Adapter,
         feishu_gateway_config(client, %{web_login_disabled: true})}
      ]
    )

    conn = get(conn, ~p"/sessions/feishu?channel_id=default&return_to=/")

    assert redirected_to(conn) == ~p"/sessions/new"
  end

  test "SSO callback refuses login when channel disables web login", %{client: client} do
    Application.put_env(:bullx, :gateway,
      adapters: [
        {{:feishu, "default"}, BullXFeishu.Adapter,
         feishu_gateway_config(client, %{web_login_disabled: true})}
      ]
    )

    state =
      Phoenix.Token.sign(BullXWeb.Endpoint, "bullx_feishu_sso_state", %{
        "provider" => "feishu",
        "channel_id" => "default",
        "return_to" => "/"
      })

    assert {:error, :web_login_disabled} =
             BullXFeishu.SSO.login_from_callback(%{"code" => "CODE", "state" => state})
  end

  test "callback logs in a bound Feishu user and discards provider tokens", %{conn: conn} do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "default", external_id: "feishu:ou_user")

    {:ok, url} =
      BullXFeishu.SSO.authorization_url(%{"channel_id" => "default", "return_to" => "/"})

    state =
      url
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()
      |> Map.fetch!("state")

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/open-apis/authen/v1/oidc/access_token" ->
          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{"access_token" => "u-token", "refresh_token" => "r-token"}
          })

        "/open-apis/authen/v1/user_info" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer u-token"]

          Req.Test.json(conn, %{
            "code" => 0,
            "data" => %{"open_id" => "ou_user", "name" => "Alice"}
          })
      end
    end)

    conn = get(conn, ~p"/sessions/feishu/callback?code=CODE&state=#{state}")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id) == user.id
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
        client: client,
        sso: %{
          enabled: true,
          redirect_uri: "http://localhost:4002/sessions/feishu/callback"
        }
      },
      attrs
    )
  end
end
