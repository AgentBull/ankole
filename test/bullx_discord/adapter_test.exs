defmodule BullXDiscord.AdapterTest do
  use ExUnit.Case, async: false

  alias BullXDiscord.Adapter

  defmodule SelfAPI do
    @response_key {__MODULE__, :response}

    def put_response(response), do: :persistent_term.put(@response_key, response)
    def clear, do: :persistent_term.erase(@response_key)

    def get, do: :persistent_term.get(@response_key)
  end

  setup do
    on_exit(&SelfAPI.clear/0)
    :ok
  end

  test "connectivity_check verifies bot credentials without starting the gateway transport" do
    SelfAPI.put_response({:ok, %{id: "bot-1", username: "BullX"}})

    assert {:ok, result} =
             Adapter.connectivity_check({:discord, "default"}, %{
               application_id: "app",
               bot_token: "bot",
               client_secret: "secret",
               self_api: SelfAPI
             })

    assert result["adapter"] == "discord"
    assert result["channel_id"] == "default"
    assert result["bot_user_id"] == "bot-1"
    assert result["credential"]["status"] == "verified"
    assert result["transport"]["long_lived_client_started"] == false
    assert result["transport"]["message_content_intent_required"] == true
    assert "stream" in result["capabilities"]
  end

  test "connectivity_check maps Discord API errors without leaking secrets" do
    SelfAPI.put_response(
      {:error,
       %Nostrum.Error.ApiError{
         status_code: 401,
         response: %{code: 0, message: "invalid token"}
       }}
    )

    assert {:error, error} =
             Adapter.connectivity_check({:discord, "default"}, %{
               application_id: "app",
               bot_token: "bot-secret",
               client_secret: "client-secret",
               self_api: SelfAPI
             })

    assert error["kind"] == "auth"
    refute inspect(error) =~ "bot-secret"
    refute inspect(error) =~ "client-secret"
  end
end
