defmodule BullXWeb.SetupSessionControllerTest do
  use BullXWeb.ConnCase, async: false

  alias BullX.Principals
  alias BullX.Principals.ActivationCode
  alias BullX.Repo

  test "GET /setup/sessions/new renders the setup gate with no-store", %{conn: conn} do
    conn = get(conn, ~p"/setup/sessions/new")

    assert html_response(conn, 200) =~ "setup/sessions/New"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "POST /setup/sessions stores setup session keys without consuming the code", %{conn: conn} do
    assert {:ok, %{code: plaintext, activation_code: code}} =
             Principals.create_or_refresh_bootstrap_activation_code()

    conn =
      conn
      |> init_test_session(%{})
      |> post(~p"/setup/sessions", %{"setup" => %{"bootstrap_code" => plaintext}})

    assert redirected_to(conn) == ~p"/setup"

    code_hash = get_session(conn, :bootstrap_activation_code_hash)
    assert is_binary(code_hash)
    assert get_session(conn, :bootstrap_activation_code_plaintext) == plaintext
    assert get_session(conn, :setup_step) == "plugins"

    stored = Repo.get!(ActivationCode, code.id)
    assert stored.used_at == nil
    assert stored.metadata["setup_gate_verified_at"]
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
