defmodule BullXWeb.SetupSessionControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullX.Principals

  test "POST /setup/sessions stores setup session keys without consuming the code", %{conn: conn} do
    assert {:ok, %{code: plaintext, code_hash: code_hash}} =
             Principals.create_or_refresh_bootstrap_activation_code()

    conn =
      conn
      |> init_test_session(%{})
      |> post(~p"/setup/sessions", %{"setup" => %{"bootstrap_code" => plaintext}})

    assert redirected_to(conn) == ~p"/setup"

    assert get_session(conn, :bootstrap_activation_code_hash) == code_hash
    assert get_session(conn, :bootstrap_activation_code_plaintext) == plaintext
    assert get_session(conn, :setup_step) == "plugins"
  end

  test "POST /setup/sessions clears old setup session keys on invalid code", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{
        bootstrap_activation_code_hash: "old-hash",
        bootstrap_activation_code_plaintext: "OLD-CODE",
        setup_step: "activate_admin"
      })
      |> post(~p"/setup/sessions", %{"setup" => %{"bootstrap_code" => "wrong-code"}})

    assert redirected_to(conn) == ~p"/setup/sessions/new"
    assert get_session(conn, :bootstrap_activation_code_hash) == nil
    assert get_session(conn, :bootstrap_activation_code_plaintext) == nil
    assert get_session(conn, :setup_step) == nil
  end
end
