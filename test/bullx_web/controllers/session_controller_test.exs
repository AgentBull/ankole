defmodule BullXWeb.SessionControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullXAccounts.ActivationCode
  alias BullXAccounts.User
  alias BullXAccounts.UserChannelAuthCode
  alias BullXAccounts.UserChannelBinding

  test "GET /sessions/new redirects to setup when users empty and bootstrap pending",
       %{conn: conn} do
    Repo.delete_all(ActivationCode)
    {:ok, _result} = BullXAccounts.create_or_refresh_bootstrap_activation_code()

    conn = get(conn, ~p"/sessions/new")

    assert redirected_to(conn) == ~p"/setup"
  end

  test "GET /sessions/new renders the form when users empty but no bootstrap pending",
       %{conn: conn} do
    Repo.delete_all(ActivationCode)

    conn = get(conn, ~p"/sessions/new")

    assert html_response(conn, 200) =~ "sessions/New"
  end

  test "GET /sessions/new renders the sessions SPA for anonymous users", %{conn: conn} do
    insert_user!(display_name: "Alice")

    conn = get(conn, ~p"/sessions/new")

    assert html_response(conn, 200) =~ "sessions/New"
  end

  test "GET /sessions/new exposes enabled Feishu Web login channels", %{conn: conn} do
    put_gateway_adapters!([
      {{:feishu, "default"}, BullXFeishu.Adapter,
       %{app_id: "cli_test", app_secret: "secret_test"}},
      {{:feishu, "disabled"}, BullXFeishu.Adapter,
       %{app_id: "cli_test", app_secret: "secret_test", web_login_disabled: true}}
    ])

    insert_user!(display_name: "Alice")

    response =
      conn
      |> get(~p"/sessions/new")
      |> html_response(200)

    assert response =~ "login_providers"
    assert response =~ "/sessions/default"
    refute response =~ "/sessions/disabled"
  end

  test "GET /sessions/new redirects home when already signed in", %{conn: conn} do
    user = insert_user!(display_name: "Alice")

    conn =
      conn
      |> init_test_session(%{user_id: user.id})
      |> get(~p"/sessions/new")

    assert redirected_to(conn) == ~p"/"
  end

  test "POST /sessions consumes a channel auth code and stores only the user id in session", %{
    conn: conn
  } do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")
    assert {:ok, code} = BullXAccounts.issue_user_channel_auth_code(:feishu, "main", "ou_1")

    conn = post(conn, ~p"/sessions", %{"session" => %{"auth_code" => code}})

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :user_id) == user.id
    assert Repo.aggregate(UserChannelAuthCode, :count) == 0
  end

  test "POST /sessions rejects expired or invalid codes", %{conn: conn} do
    conn = post(conn, ~p"/sessions", %{"session" => %{"auth_code" => "NOPE"}})

    assert redirected_to(conn) == ~p"/sessions/new"

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             "Invalid or expired authentication code."
  end

  test "banned users cannot establish a web session with an existing code", %{conn: conn} do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")
    assert {:ok, code} = BullXAccounts.issue_user_channel_auth_code(:feishu, "main", "ou_1")

    user
    |> User.changeset(%{status: :banned})
    |> Repo.update!()

    conn = post(conn, ~p"/sessions", %{"session" => %{"auth_code" => code}})

    assert redirected_to(conn) == ~p"/sessions/new"
    assert get_session(conn, :user_id) == nil
  end

  test "DELETE /sessions clears the session and redirects to sign-in", %{conn: conn} do
    user = insert_user!(display_name: "Alice")
    insert_binding!(user, adapter: "feishu", channel_id: "main", external_id: "ou_1")
    assert {:ok, code} = BullXAccounts.issue_user_channel_auth_code(:feishu, "main", "ou_1")

    conn = post(conn, ~p"/sessions", %{"session" => %{"auth_code" => code}})
    assert get_session(conn, :user_id) == user.id

    conn = delete(conn, ~p"/sessions")

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

  defp put_gateway_adapters!(adapters) do
    previous = Application.get_env(:bullx, :gateway)

    Application.put_env(:bullx, :gateway, adapters: adapters)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bullx, :gateway)
        value -> Application.put_env(:bullx, :gateway, value)
      end
    end)
  end
end
