defmodule Ankole.RuntimeEventsTest do
  use ExUnit.Case, async: true

  alias Ankole.RuntimeEvents
  alias Ankole.RuntimeEvents.Event

  test "outbox due events carry typed scheduling metadata" do
    due_at = ~U[2026-07-07 10:00:00.000000Z] |> DateTime.to_iso8601()

    assert [
             %Event{
               kind: :outbox_due,
               channel: channel,
               payload: %{"due_at" => ^due_at},
               due_at: ~U[2026-07-07 10:00:00.000000Z],
               timer_key: {channel, "agent-a", "lark", "outbound-1"}
             }
           ] =
             RuntimeEvents.expand(RuntimeEvents.outbox_due_channel(), %{
               "agent_uid" => "agent-a",
               "binding_name" => "lark",
               "outbound_key" => "outbound-1",
               "due_at" => due_at
             })
  end

  test "worker deadline channel expands to derived deadline events" do
    stale_at = ~U[2026-07-07 10:00:00.000000Z] |> DateTime.to_iso8601()
    delete_at = ~U[2026-07-07 11:00:00.000000Z] |> DateTime.to_iso8601()

    assert [
             %Event{
               kind: :worker_delete_deadline,
               channel: delete_channel,
               payload: %{"due_at" => ^delete_at},
               due_at: ~U[2026-07-07 11:00:00.000000Z],
               timer_key: {delete_channel, "worker-1"}
             },
             %Event{
               kind: :worker_stale_deadline,
               channel: stale_channel,
               payload: %{"due_at" => ^stale_at},
               due_at: ~U[2026-07-07 10:00:00.000000Z],
               timer_key: {stale_channel, "worker-1"}
             }
           ] =
             RuntimeEvents.expand(RuntimeEvents.worker_deadline_channel(), %{
               "worker_id" => "worker-1",
               "transport_route" => "route-1",
               "stale_at" => stale_at,
               "delete_at" => delete_at
             })

    assert String.starts_with?(delete_channel, RuntimeEvents.worker_deadline_channel())
    assert String.starts_with?(stale_channel, RuntimeEvents.worker_deadline_channel())
  end

  test "activation deadlines use the grace-adjusted due time" do
    lease_expires_at = ~U[2026-07-07 10:00:00.000000Z] |> DateTime.to_iso8601()
    due_at = ~U[2026-07-07 10:02:00.000000Z] |> DateTime.to_iso8601()

    assert [
             %Event{
               kind: :activation_deadline,
               due_at: ~U[2026-07-07 10:02:00.000000Z],
               payload: %{
                 "activation_uid" => "activation-1",
                 "lease_expires_at" => ^lease_expires_at,
                 "due_at" => ^due_at
               }
             }
           ] =
             RuntimeEvents.expand(RuntimeEvents.activation_deadline_channel(), %{
               "activation_uid" => "activation-1",
               "lease_expires_at" => lease_expires_at,
               "due_at" => due_at
             })
  end

  test "workflow run ready events carry typed scheduling metadata" do
    payload = %{"run_id" => 1_000}
    channel = RuntimeEvents.workflow_run_ready_channel()

    assert channel in RuntimeEvents.channels()

    assert [
             %Event{
               kind: :workflow_run_ready,
               channel: ^channel,
               payload: ^payload,
               due_at: nil,
               timer_key: {^channel, 1_000}
             }
           ] = RuntimeEvents.expand(channel, payload)
  end

  test "missing timer key fields preserve the old payload fallback key" do
    payload = %{"due_at" => DateTime.to_iso8601(~U[2026-07-07 10:00:00.000000Z])}

    assert [%Event{timer_key: {channel, ^payload}}] =
             RuntimeEvents.expand(RuntimeEvents.inbound_batch_due_channel(), payload)

    assert channel == RuntimeEvents.inbound_batch_due_channel()
  end

  test "unknown channels stay runnable so handlers can log the ignored event" do
    payload = %{"field" => "value"}

    assert [
             %Event{
               kind: :unknown,
               channel: "unknown-channel",
               payload: ^payload,
               due_at: nil,
               timer_key: {"unknown-channel", ^payload}
             }
           ] = RuntimeEvents.expand("unknown-channel", payload)
  end
end
