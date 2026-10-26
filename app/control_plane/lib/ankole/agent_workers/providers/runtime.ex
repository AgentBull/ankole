defmodule Ankole.AgentWorkers.Providers.Runtime do
  @moduledoc "The loaded configuration passed to Worker provider adapters."

  @enforce_keys [:id, :provider_id, :kind, :settings, :secrets, :runtime, :settings_digest]
  @derive {Inspect, except: [:secrets, :runtime]}
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          provider_id: String.t(),
          kind: String.t(),
          settings: map(),
          secrets: map(),
          runtime: Ankole.AgentWorkers.Config.t(),
          settings_digest: String.t()
        }
end
