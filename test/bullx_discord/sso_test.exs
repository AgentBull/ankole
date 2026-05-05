defmodule BullXDiscord.SSOTest do
  use ExUnit.Case, async: false

  alias BullXDiscord.{Config, SSO}

  defmodule AccountsStub do
    @pid_key {__MODULE__, :pid}

    def put_pid(pid), do: :persistent_term.put(@pid_key, pid)
    def clear, do: :persistent_term.erase(@pid_key)

    def login_from_provider(input) do
      send(:persistent_term.get(@pid_key), {:provider_input, input})
      {:ok, %{id: "user-1"}, %{id: "binding-1"}}
    end
  end

  setup do
    AccountsStub.put_pid(self())
    on_exit(&AccountsStub.clear/0)
    :ok
  end

  test "builds Discord authorization URLs with identify and email scopes" do
    assert {:ok, url} =
             SSO.authorization_url(
               "default",
               "https://bullx.test/sessions/discord/default/callback",
               "STATE",
               config: config()
             )

    query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert String.starts_with?(url, "https://discord.com/oauth2/authorize?")
    assert query["client_id"] == "app"
    assert query["redirect_uri"] == "https://bullx.test/sessions/discord/default/callback"
    assert query["response_type"] == "code"
    assert query["scope"] == "identify email"
    assert query["state"] == "STATE"
  end

  test "web login can be disabled per Discord channel" do
    assert {:error, :web_login_disabled} =
             SSO.authorization_url("default", "https://bullx.test/callback", "STATE",
               config: config(%{web_login_disabled: true})
             )
  end

  test "callback exchanges code, fetches current user, and keeps only verified email" do
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
            "verified" => true,
            "locale" => "en-US"
          })
      end
    end)

    assert {:ok, %{user: %{id: "user-1"}, return_to: "/home"}} =
             SSO.login_from_callback(
               %{
                 "channel_id" => "default",
                 "redirect_uri" => "https://bullx.test/callback",
                 "code" => "CODE",
                 "return_to" => "/home"
               },
               config: config(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    assert_receive {:provider_input, input}
    assert input.provider == :discord
    assert input.provider_user_id == "discord-user-1"
    assert input.external_id == "discord:discord-user-1"
    assert input.profile["display_name"] == "Alice"
    assert input.profile["email"] == "alice@example.test"
    assert input.metadata["verified_email"] == true

    assert_receive {:token_body,
                    %{
                      "client_id" => "app",
                      "client_secret" => "secret",
                      "code" => "CODE",
                      "grant_type" => "authorization_code",
                      "redirect_uri" => "https://bullx.test/callback"
                    }}
  end

  test "callback ignores unverified Discord email" do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/oauth2/token" ->
          Req.Test.json(conn, %{"access_token" => "access-token"})

        "/api/users/@me" ->
          Req.Test.json(conn, %{
            "id" => "discord-user-1",
            "username" => "alice",
            "email" => "alice@example.test",
            "verified" => false
          })
      end
    end)

    assert {:ok, _result} =
             SSO.login_from_callback(
               %{
                 "channel_id" => "default",
                 "redirect_uri" => "https://bullx.test/callback",
                 "code" => "CODE"
               },
               config: config(%{req_options: [plug: {Req.Test, __MODULE__}]})
             )

    assert_receive {:provider_input, input}
    refute Map.has_key?(input.profile, "email")
    assert input.metadata["verified_email"] == false
  end

  defp config(attrs \\ %{}) do
    base = %{
      application_id: "app",
      bot_token: "bot",
      client_secret: "secret",
      accounts_module: AccountsStub
    }

    {:ok, config} = Config.normalize({:discord, "default"}, Map.merge(base, attrs))
    config
  end
end
