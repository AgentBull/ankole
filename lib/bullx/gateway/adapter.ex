defmodule BullX.Gateway.Adapter do
  @moduledoc """
  Behaviour implemented by trusted Gateway transport adapters.

  Adapters own provider semantics: authenticity checks, provider payload
  parsing, provider API calls, and provider-specific source config. Gateway
  core owns the normalized carrier contracts and durable delivery boundaries.
  """

  alias BullX.Gateway.SourceConfig

  @type runtime_config :: SourceConfig.t()
  @type provider_payload :: term()
  @type request_metadata :: map()
  @type normalized_input :: map()
  @type delivery :: term()
  @type outcome :: term()
  @type adapter_error :: {:error, map()}

  @callback config_schema() :: term()
  @callback normalize_config(map()) :: {:ok, map()} | {:error, term()}
  @callback public_config(map()) :: map()
  @callback capabilities() :: map()
  @callback connectivity_check(runtime_config()) :: {:ok, map()} | adapter_error()
  @callback source_child_spec(runtime_config()) :: Supervisor.child_spec() | :ignore
  @callback normalize_inbound(provider_payload(), runtime_config(), request_metadata()) ::
              {:ok, normalized_input()} | adapter_error()
  @callback deliver(delivery(), runtime_config()) :: {:ok, outcome()} | adapter_error()
  @callback stream(delivery(), Enumerable.t(), runtime_config()) ::
              {:ok, outcome()} | adapter_error()
end
