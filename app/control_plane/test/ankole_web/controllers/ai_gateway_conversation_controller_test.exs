defmodule AnkoleWeb.AIGatewayConversationControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    allow_cache_database_access()
    {:ok, true} = SetupConfig.put_completed(true)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "a malformed conversation id yields an empty message page", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> get(~p"/api/v1/ai-gateway/conversations/not-a-uuid/messages")

    assert %{"messages" => [], "next_cursor" => nil} = json_response(conn, 200)
  end

  test "a malformed conversation id is not found on show", %{conn: conn} do
    conn =
      conn
      |> bearer_conn()
      |> get(~p"/api/v1/ai-gateway/conversations/not-a-uuid")

    assert %{"error" => %{"code" => "not_found", "message" => message}} = json_response(conn, 404)
    assert is_binary(message)
  end
end
