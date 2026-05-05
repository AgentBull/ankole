defmodule BullXWeb.DiscordAuthControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullXAccounts.{User, UserChannelBinding}

  @callback_url "http://localhost:4000/sessions/discord/default/callback"

  setup do
    previous_gateway = Application.get_env(:bullx, :gateway)

    Application.put_env(:bullx, :gateway,
      adapters: [
        {{:discord, "default"}, BullXDiscord.Adapter,
         discord_gateway_config(%{req_options: [plug: {Req.Test, __MODULE__}]})}
      ]
    )

    on_exit(fn ->
      case previous_gateway do
        nil -> Application.delete_env(:bullx, :gateway)
        value -> Application.put_env(:bullx, :gateway, value)
      end
    end)

    :ok
  end

  test "GET /sessions/discord/:channel_id redirects to Discord authorization URL and stores cookie state",
       %{conn: conn} do
    conn = %{conn | scheme: :http, host: "internal-host", port: 4000}
    conn = get(conn, ~p"/sessions/discord/default?return_to=/")

    redirect = redirected_to(conn, 302)
    query = auth_redirect_query(redirect)

    assert redirect =~ "https://discord.com/oauth2/authorize"
    assert query["client_id"] == "app"
    assert query["redirect_uri"] == @callback_url
    assert query["response_type"] == "code"
    assert query["scope"] == "identify email"
    assert is_binary(query["state"])

    assert %{
             "provider" => "discord",
             "channel_id" => "default",
             "return_to" => "/",
             "nonce" => nonce
           } = get_session(conn, :session_controller_state)

    assert nonce == query["state"]
  end

  test "GET /sessions/discord/:channel_id refuses provider login when channel disables web login",
       %{conn: conn} do
    Application.put_env(:bullx, :gateway,
      adapters: [
        {{:discord, "default"}, BullXDiscord.Adapter,
         discord_gateway_config(%{web_login_disabled: true})}
      ]
    )

    conn = get(conn, ~p"/sessions/discord/default?return_to=/")

    assert redirected_to(conn) == ~p"/sessions/new"
    assert get_session(conn, :session_controller_state) == nil
  end

  test "callback logs in a bound Discord user and discards provider tokens", %{conn: conn} do
    user = insert_user!(display_name: "Alice")

    insert_binding!(user,
      adapter: "discord",
      channel_id: "default",
      external_id: "discord:discord-user-1"
    )

    state = "STATE"
    parent = self()

    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/oauth2/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(parent, {:token_body, URI.decode_query(body)})
          Req.Test.json(conn, %{"access_token" => "access-token"})

        "/api/users/@me" ->
          assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer access-token"]

          Req.Test.json(conn, %{
            "id" => "discord-user-1",
            "username" => "alice",
            "global_name" => "Alice",
            "email" => "alice@example.test",
            "verified" => true
          })
      end
    end)

    conn =
      conn
      |> init_test_session(%{
        session_controller_state: %{
          "provider" => "discord",
          "channel_id" => "default",
          "return_to" => "/",
          "nonce" => state,
          "issued_at" => System.system_time(:second)
        }
      })
      |> get(~p"/sessions/discord/default/callback?code=CODE&state=#{state}")

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id) == user.id
    assert get_session(conn, :session_controller_state) == nil

    assert_receive {:token_body,
                    %{
                      "grant_type" => "authorization_code",
                      "client_id" => "app",
                      "client_secret" => "secret",
                      "code" => "CODE",
                      "redirect_uri" => @callback_url
                    }}
  end

  test "callback rejects mismatched cookie state", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{
        session_controller_state: %{
          "provider" => "discord",
          "channel_id" => "other",
          "return_to" => "/",
          "nonce" => "STATE",
          "issued_at" => System.system_time(:second)
        }
      })
      |> get(~p"/sessions/discord/default/callback?code=CODE&state=STATE")

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

  defp discord_gateway_config(attrs) do
    Map.merge(
      %{
        application_id: "app",
        bot_token: "bot",
        client_secret: "secret"
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
