defmodule BullX.Gateway.InboundError do
  @moduledoc """
  Redacted Gateway inbound error returned before provider acknowledgement.

  The struct deliberately carries a short safe message and JSON-neutral details
  only. It must not contain raw provider bodies, tokens, signatures, or private
  adapter config.
  """

  @classes [
    :malformed,
    :policy_denied,
    :security_denied,
    :router_unavailable,
    :router_contract,
    :store_unavailable,
    :adapter_contract,
    :unknown_source
  ]

  @enforce_keys [:class, :retryable?, :safe_message]
  defstruct [:class, :retryable?, :safe_message, details: %{}]

  @type class ::
          :malformed
          | :policy_denied
          | :security_denied
          | :router_unavailable
          | :router_contract
          | :store_unavailable
          | :adapter_contract
          | :unknown_source

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
      retryable?: retryable?(class),
      safe_message: safe_message,
      details: redacted_details(details)
    }
  end

  defp retryable?(class) when class in [:router_unavailable, :store_unavailable], do: true
  defp retryable?(_class), do: false

  defp redacted_details(details) when is_map(details) do
    case BullX.Gateway.JSON.stringify_keys(details) do
      {:ok, details} -> details
      :error -> %{}
    end
  end

  defp redacted_details(_details), do: %{}
end
