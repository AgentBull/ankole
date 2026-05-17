defmodule BullX.EventBus.ConfigTest do
  use ExUnit.Case, async: false

  alias BullX.EventBus.Config

  setup do
    previous = Application.get_env(:bullx, :event_bus)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bullx, :event_bus)
        value -> Application.put_env(:bullx, :event_bus, value)
      end
    end)

    :ok
  end

  test "rejects invalid integer config instead of silently falling back" do
    Application.put_env(:bullx, :event_bus, stream_retention_seconds: 0)

    assert_raise ArgumentError, fn -> Config.stream_retention_seconds() end
  end

  test "allows disabling the cleanup scheduler in tests" do
    Application.put_env(:bullx, :event_bus, target_session_cleanup_interval_ms: false)

    assert Config.target_session_cleanup_interval_ms() == false
  end
end
