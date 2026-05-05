defmodule BullXWeb.SetupSessionControllerTest do
  use BullXWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias BullX.Repo
  alias BullXAccounts.ActivationCode
  alias BullXAccounts.User

  @config_key "bullx.i18n_default_locale"

  setup do
    previous_config = Repo.get(BullX.Config.AppConfig, @config_key)

    on_exit(fn ->
      case previous_config do
        nil -> BullX.Config.delete(@config_key)
        %BullX.Config.AppConfig{value: value} -> BullX.Config.put(@config_key, value)
      end

      BullX.I18n.reload()
    end)

    :ok
  end

  test "GET /setup/sessions/new renders the gate when users is empty", %{conn: conn} do
    conn = get(conn, ~p"/setup/sessions/new")

    assert html_response(conn, 200) =~ "setup/sessions/New"
  end

  test "GET /setup/sessions/new redirects home once a user exists", %{conn: conn} do
    insert_user!(display_name: "Alice")

    conn = get(conn, ~p"/setup/sessions/new")

    assert redirected_to(conn) == ~p"/"
  end

  test "POST /setup/sessions stores the hash and applies a supported locale on a valid code", %{
    conn: conn
  } do
    Repo.delete_all(ActivationCode)
    {:ok, %{code: plaintext}} = BullXAccounts.create_or_refresh_bootstrap_activation_code()

    params = %{"setup" => %{"bootstrap_code" => plaintext, "locale" => "zh-Hans-CN"}}
    conn = post(conn, ~p"/setup/sessions", params)

    assert redirected_to(conn) == ~p"/setup"
    assert is_binary(get_session(conn, :bootstrap_activation_code_hash))

    assert BullXAccounts.bootstrap_activation_code_valid_for_hash?(
             get_session(conn, :bootstrap_activation_code_hash)
           )

    assert BullX.Config.I18n.i18n_default_locale!() == "zh-Hans-CN"
  end

  test "POST /setup/sessions ignores invalid locale submissions after a valid code", %{
    conn: conn
  } do
    Repo.delete_all(ActivationCode)
    {:ok, %{code: plaintext}} = BullXAccounts.create_or_refresh_bootstrap_activation_code()
    before_locale = BullX.Config.I18n.i18n_default_locale!()

    cases = [
      {%{"bootstrap_code" => plaintext, "locale" => "fr-FR"},
       "Setup gate ignoring unsupported locale"},
      {%{"bootstrap_code" => plaintext, "locale" => " "},
       "Setup gate ignoring blank or missing locale"},
      {%{"bootstrap_code" => plaintext}, "Setup gate ignoring blank or missing locale"}
    ]

    Enum.each(cases, fn {params, expected_log} ->
      log =
        capture_log(fn ->
          conn = post(conn, ~p"/setup/sessions", params)

          assert redirected_to(conn) == ~p"/setup"
          assert is_binary(get_session(conn, :bootstrap_activation_code_hash))
        end)

      assert log =~ expected_log
      assert BullX.Config.I18n.i18n_default_locale!() == before_locale
    end)
  end

  test "POST /setup/sessions does not write session or config when the code is invalid", %{
    conn: conn
  } do
    Repo.delete_all(ActivationCode)
    {:ok, _result} = BullXAccounts.create_or_refresh_bootstrap_activation_code()

    before_locale = BullX.Config.I18n.i18n_default_locale!()
    params = %{"bootstrap_code" => "WRONG-CODE", "locale" => "zh-Hans-CN"}
    conn = post(conn, ~p"/setup/sessions", params)

    assert redirected_to(conn) == ~p"/setup/sessions/new"
    assert get_session(conn, :bootstrap_activation_code_hash) == nil
    assert BullX.Config.I18n.i18n_default_locale!() == before_locale

    assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
             BullX.I18n.t("setup.bootstrap.activation_code_invalid")
  end

  test "POST /setup/sessions falls through to / once setup is complete", %{conn: conn} do
    insert_user!(display_name: "Alice")

    params = %{"bootstrap_code" => "anything", "locale" => "en-US"}
    conn = post(conn, ~p"/setup/sessions", params)

    assert redirected_to(conn) == ~p"/"
    assert get_session(conn, :bootstrap_activation_code_hash) == nil
  end

  defp insert_user!(attrs) do
    %User{}
    |> User.changeset(Map.new(attrs))
    |> Repo.insert!()
  end
end
