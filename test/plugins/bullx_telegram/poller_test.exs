defmodule BullxTelegram.PollerTest do
  use ExUnit.Case, async: false

  alias BullxTelegram.{Channel, Poller, Source}

  defmodule API do
    def request(%Source{} = source, "getUpdates", params) do
      test_pid = Keyword.fetch!(source.req_options, :test_pid)
      send(test_pid, {:get_updates, params})

      {:ok,
       [
         %{
           "update_id" => 123,
           "message" => %{
             "chat" => %{"id" => 1, "type" => "private"},
             "from" => %{"id" => 1, "is_bot" => false},
             "text" => "hello"
           }
         }
       ]}
    end
  end

  test "failed update dispatch does not advance polling offset" do
    source = %Source{
      id: "poller-failure-#{System.unique_integer([:positive])}",
      bot_token: "123456:ABC",
      bot_id: "123456",
      bot_username: "bullx_bot",
      start_transport?: false,
      api_module: __MODULE__.API,
      req_options: [test_pid: self()]
    }

    start_supervised!({Channel, source})
    poller = start_supervised!({Poller, source})

    send(poller, :poll)

    assert_receive {:get_updates, params}, 500
    refute Map.has_key?(params, "offset")
    assert_poller_state(poller, nil, 1)
  end

  defp assert_poller_state(poller, offset, retry_count, attempts \\ 20)

  defp assert_poller_state(poller, offset, retry_count, attempts) when attempts > 0 do
    case :sys.get_state(poller) do
      %Poller{offset: ^offset, retry_count: ^retry_count} ->
        :ok

      _state ->
        Process.sleep(10)
        assert_poller_state(poller, offset, retry_count, attempts - 1)
    end
  end

  defp assert_poller_state(poller, _offset, _retry_count, 0) do
    flunk("unexpected poller state: #{inspect(:sys.get_state(poller))}")
  end
end
