defmodule Ankole.SignalsGateway.ActorRuntime.AgentWorkers.ProviderKind.Definition do
  @moduledoc """
  The configuration and capabilities of one Worker provider kind.

  `max_instance_lifetime` is in seconds. The provider's `started_at` observation
  supplies the start of this clock, including a reset on resume if applicable.
  A kind can use `instance_lifetime/1` for a shorter configured lifetime.
  """

  @enforce_keys [:kind, :schema, :example, :credentials, :pause]
  defstruct @enforce_keys ++ [max_instance_lifetime: nil]

  @type t :: %__MODULE__{
          kind: String.t(),
          schema: map(),
          example: String.t(),
          credentials: %{String.t() => %{required: boolean()}},
          pause: boolean(),
          max_instance_lifetime: pos_integer() | nil
        }
end
