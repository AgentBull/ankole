defmodule AnkoleWeb.AuthControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "return_to keeps local paths and rejects protocol-relative or backslash-relative paths" do
    assert WebSession.safe_return_to("/console") == "/console"
    assert WebSession.safe_return_to("/console/agents") == "/console/agents"
    assert WebSession.safe_return_to("//evil.example/console") == "/console"
    assert WebSession.safe_return_to("/\\evil.example/console") == "/console"
    assert WebSession.safe_return_to("https://evil.example/console") == "/console"
  end

  test "OIDC callback without matching state fails closed", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> get(~p"/auth/oidc/lark-main/callback", %{"code" => "code", "state" => "missing"})

    assert json_response(conn, 400)["error"] == "invalid OIDC state"
    assert get_session(conn, :admin_session) == nil
  end

  test "OIDC callback rejects provider mismatch", %{conn: conn} do
    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_admin_oidc_state(%{
        provider_id: "lark-main",
        state: "state-1",
        redirect_uri: "http://localhost/auth/oidc/lark-main/callback",
        return_to: "/console"
      })
      |> get(~p"/auth/oidc/other-main/callback", %{"code" => "code", "state" => "state-1"})

    assert json_response(conn, 400)["error"] == "invalid OIDC state"
    assert get_session(conn, :admin_session) == nil
  end

  test "OIDC callback rejects expired state", %{conn: conn} do
    expired_at = System.system_time(:second) - 1

    conn =
      conn
      |> init_test_session(%{
        admin_oidc_state: %{
          "provider_id" => "lark-main",
          "state" => "state-1",
          "redirect_uri" => "http://localhost/auth/oidc/lark-main/callback",
          "return_to" => "/console",
          "expires_at" => expired_at
        }
      })
      |> get(~p"/auth/oidc/lark-main/callback", %{"code" => "code", "state" => "state-1"})

    assert json_response(conn, 400)["error"] == "invalid OIDC state"
    assert get_session(conn, :admin_session) == nil
  end

  test "bootstrap OIDC state cannot be replayed as admin login after setup is complete", %{
    conn: conn
  } do
    assert {:ok, true} = SetupConfig.put_completed(true)

    conn =
      conn
      |> init_test_session(%{})
      |> WebSession.put_setup_oidc_state(%{
        provider_id: "lark-main",
        state: "setup-state",
        redirect_uri: "http://localhost/auth/oidc/lark-main/callback",
        return_to: "/console"
      })
      |> get(~p"/auth/oidc/lark-main/callback", %{"code" => "code", "state" => "setup-state"})

    assert json_response(conn, 409)["error"] == "setup already completed"
    assert get_session(conn, :admin_session) == nil
    assert get_session(conn, :admin_oidc_state) == nil
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
