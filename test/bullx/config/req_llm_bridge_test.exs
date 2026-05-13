defmodule BullX.Config.ReqLLMBridgeTest do
  use BullX.DataCase, async: false

  @db_key "bullx.req_llm.receive_timeout_ms"

  setup do
    cache_pid = GenServer.whereis(BullX.Config.Cache)
    Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), cache_pid)
    BullX.Config.Cache.refresh_all()

    previous_receive_timeout = Application.get_env(:req_llm, :receive_timeout)

    on_exit(fn ->
      BullX.Repo.delete_all(BullX.Config.AppConfig)
      BullX.Config.Cache.refresh_all()
      restore_req_llm_env(:receive_timeout, previous_receive_timeout)
    end)

    :ok
  end

  test "syncs req_llm call-time settings after config writes and deletes" do
    assert :ok = BullX.Config.Writer.put(@db_key, "12345")
    assert Application.get_env(:req_llm, :receive_timeout) == 12_345

    assert :ok = BullX.Config.Writer.delete(@db_key)
    assert Application.get_env(:req_llm, :receive_timeout) == nil
  end

  defp restore_req_llm_env(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore_req_llm_env(key, value), do: Application.put_env(:req_llm, key, value)
end
