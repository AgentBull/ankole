defmodule BullX.MailBoxTest do
  use BullX.DataCase, async: false

  alias BullX.MailBox
  alias BullX.MailBox.{DeliveryRule, Entry}
  alias BullX.Repo

  test "route fans out to every matching rule even when priorities are equal" do
    insert_delivery_rule!("fanout a", "agent-a", 100)
    insert_delivery_rule!("fanout b", "agent-b", 100)

    assert {:ok, results} = MailBox.route(cloud_event("fanout-1"))
    assert length(results) == 2
    assert Enum.all?(results, &match?({:ok, %{entry: %Entry{}}}, &1))

    entries = Repo.all(Entry) |> Repo.preload(:mailbox)

    assert Enum.map(entries, & &1.mailbox.receiver_ref) |> Enum.sort() == [
             "agent-a",
             "agent-b"
           ]
  end

  test "claim_ready reclaims expired leased entries" do
    assert {:ok, %{entry: %Entry{} = entry}} =
             MailBox.deliver(%{
               cloud_event: cloud_event("lease-1"),
               receiver_type: "blackhole",
               receiver_ref: "sink",
               attention: :system,
               session_key: "lease-test",
               reply_address: %{}
             })

    assert {:ok, [%Entry{id: entry_id, lease_holder: "first"}]} =
             MailBox.claim_ready(1, holder: "first")

    assert entry_id == entry.id
    assert {:ok, []} = MailBox.claim_ready(1, holder: "second")

    past = DateTime.add(DateTime.utc_now(:microsecond), -1, :second)

    Repo.update_all(
      from(entry in Entry, where: entry.id == ^entry.id),
      set: [lease_expires_at: past]
    )

    assert {:ok, [%Entry{id: ^entry_id, lease_holder: "second", attempts: 2}]} =
             MailBox.claim_ready(1, holder: "second")
  end

  test "dispatcher wakes for delivered entries instead of waiting for idle poll" do
    start_supervised!({BullX.MailBox.Dispatcher, interval_ms: 10, claim_limit: 20})

    assert {:ok, %{entry: %Entry{} = entry}} =
             MailBox.deliver(%{
               cloud_event: cloud_event("wake-1"),
               receiver_type: "blackhole",
               receiver_ref: "sink",
               attention: :system,
               session_key: "wake-test",
               available_delay_ms: 50,
               reply_address: %{}
             })

    assert_processed(entry.id)
  end

  test "dispatcher stops scheduling itself when there is no pending work" do
    pid = start_supervised!({BullX.MailBox.Dispatcher, interval_ms: 10, claim_limit: 20})

    assert_idle_dispatcher(pid)
  end

  defp insert_delivery_rule!(name, receiver_ref, priority) do
    %DeliveryRule{}
    |> DeliveryRule.changeset(%{
      name: name,
      active: true,
      priority: priority,
      match_expr: ~s(type == "bullx.test.mail"),
      receiver_type: "blackhole",
      receiver_ref: receiver_ref,
      attention: :system,
      available_delay_ms: 0,
      metadata: %{}
    })
    |> Repo.insert!()
  end

  defp cloud_event(id) do
    %{
      "specversion" => "1.0",
      "id" => id,
      "source" => "bullx://test/mail-box",
      "type" => "bullx.test.mail",
      "time" => "2026-05-27T00:00:00Z",
      "datacontenttype" => "application/json",
      "data" => %{"reply_address" => %{"adapter" => "test", "channel_id" => "main"}}
    }
  end

  defp assert_processed(entry_id, attempts \\ 20)

  defp assert_processed(entry_id, attempts) when attempts > 0 do
    case Repo.get!(Entry, entry_id).status do
      :processed ->
        :ok

      _status ->
        Process.sleep(25)
        assert_processed(entry_id, attempts - 1)
    end
  end

  defp assert_processed(entry_id, 0) do
    status = Repo.get!(Entry, entry_id).status
    flunk("expected mailbox entry #{entry_id} to be processed, got: #{inspect(status)}")
  end

  defp assert_idle_dispatcher(pid, attempts \\ 20)

  defp assert_idle_dispatcher(pid, attempts) when attempts > 0 do
    case :sys.get_state(pid).timer_ref do
      nil ->
        :ok

      _timer_ref ->
        Process.sleep(25)
        assert_idle_dispatcher(pid, attempts - 1)
    end
  end

  defp assert_idle_dispatcher(pid, 0) do
    flunk(
      "expected mailbox dispatcher to stop scheduling itself, got: #{inspect(:sys.get_state(pid))}"
    )
  end
end
