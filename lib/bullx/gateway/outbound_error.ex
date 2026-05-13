defmodule BullX.Gateway.OutboundError do
  @moduledoc """
  Redacted Gateway outbound error returned before external delivery acceptance.
  """

  @classes [
    :malformed,
    :unknown_source,
    :unsupported_op,
    :already_dead_lettered,
    :not_replayable,
    :store_unavailable
  ]

  @enforce_keys [:class, :retryable?, :safe_message]
  defstruct [:class, :retryable?, :safe_message, details: %{}]

  @type class ::
          :malformed
          | :unknown_source
          | :unsupported_op
          | :already_dead_lettered
          | :not_replayable
          | :store_unavailable

  @type t :: %__MODULE__{
          class: class(),
          retryable?: boolean(),
          safe_message: String.t(),
          details: map()
        }

  @spec new(class(), String.t(), map()) :: t()
  def new(class, safe_message, details \\ %{})
      when class in @classes and is_binary(safe_message) do
    %__MODULE__{
      class: class,
      retryable?: class == :store_unavailable,
      safe_message: safe_message,
      details: redacted_details(details)
    }
  end

  defp redacted_details(details) when is_map(details) do
    case BullX.Gateway.JSON.stringify_keys(details) do
      {:ok, details} -> details
      :error -> %{}
    end
  end

  defp redacted_details(_details), do: %{}
end
