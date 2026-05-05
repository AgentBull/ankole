defmodule BullXTelegram.AdapterTest do
  use ExUnit.Case, async: false

  alias BullXTelegram.Adapter

  defmodule ApiStub do
    @response_key {__MODULE__, :response}

    def put_response(response), do: :persistent_term.put(@response_key, response)
    def clear, do: :persistent_term.erase(@response_key)
    def request(_token, "getMe", []), do: :persistent_term.get(@response_key)
  end

  setup do
    on_exit(&ApiStub.clear/0)
    :ok
  end

  test "connectivity_check verifies bot credentials without starting polling or setting webhook" do
    ApiStub.put_response({:ok, %{"id" => 123, "username" => "BullXBot"}})

    assert {:ok, result} =
             Adapter.connectivity_check({:telegram, "default"}, %{
               bot_token: "bot",
               bot_username: "BullXBot",
               api_module: ApiStub
             })

    assert result["adapter"] == "telegram"
    assert result["channel_id"] == "default"
    assert result["bot_id"] == "123"
    assert result["bot_username"] == "BullXBot"
    assert result["transport"]["mode"] == "polling"
    assert result["transport"]["long_lived_client_started"] == false
    assert "stream" in result["capabilities"]
  end
end
