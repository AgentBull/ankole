defmodule Ankole.Brain.SignalsTriggersTest do
  use Ankole.DataCase, async: true

  alias Ankole.Brain.Jobs.ProcessChannelSlice
  alias Ankole.Brain.SignalsTriggers
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Utils

  # The conversation key carries the "signal-channel:" prefix while the
  # Channel table stores the bare id; the trigger must strip the prefix or
  # no conversation ending ever enqueues learning.
  test "an ended signal conversation enqueues slice processing for its channel" do
    channel = insert_channel!()
    conversation_key = Utils.signal_session_id(channel.id)

    assert :ok = SignalsTriggers.conversation_ended_in_tx(Repo, conversation_key)

    assert_enqueued(
      worker: ProcessChannelSlice,
      args: %{"channel_id" => channel.id}
    )
  end

  test "non-channel conversation keys no-op" do
    assert :ok = SignalsTriggers.conversation_ended_in_tx(Repo, "stateful-responses-api:x")
    assert :ok = SignalsTriggers.conversation_ended_in_tx(Repo, "signal-channel:missing")

    refute_enqueued(worker: ProcessChannelSlice)
  end

  defp insert_channel! do
    now = DateTime.utc_now(:microsecond)

    Repo.insert!(
      Channel.changeset(%Channel{}, %{
        id: "lark:oc_trigger_#{System.unique_integer([:positive])}",
        kind: :im_group,
        reply_mode: :entry,
        metadata: %{},
        raw_payload: %{},
        first_seen_at: now,
        last_seen_at: now
      })
    )
  end
end
