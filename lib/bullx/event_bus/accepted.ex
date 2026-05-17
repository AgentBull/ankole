defmodule BullX.EventBus.Accepted do
  @moduledoc """
  Public result for an EventBus acceptance attempt that reached a terminal
  EventBus outcome.
  """

  @enforce_keys [:status, :event_source, :event_id]
  defstruct [
    :status,
    :event_source,
    :event_id,
    :rule_id,
    :target_session_id,
    :side_channel_entry_id
  ]

  @type status :: :accepted | :duplicate | :accepted_ignored

  @type t :: %__MODULE__{
          status: status(),
          event_source: String.t(),
          event_id: String.t(),
          rule_id: String.t() | nil,
          target_session_id: String.t() | nil,
          side_channel_entry_id: String.t() | nil
        }
end
