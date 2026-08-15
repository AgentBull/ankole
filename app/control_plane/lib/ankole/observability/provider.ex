defmodule Ankole.Observability.Provider do
  @moduledoc false

  alias Ankole.Observability.Providers.Langfuse
  alias Ankole.Observability.Providers.LangSmith
  alias Ankole.Observability.Providers.OpenTelemetry

  @providers [
    {"opentelemetry", OpenTelemetry},
    {"langfuse", Langfuse},
    {"langsmith", LangSmith}
  ]

  @type name :: String.t()
  @type implementation :: module()

  @type trace_context :: %{
          principal_uid: String.t() | nil,
          principal_type: String.t() | nil,
          user_id: String.t() | nil,
          actor_event_id: String.t() | nil,
          session_id: String.t() | nil,
          originator: String.t() | nil,
          caller: String.t() | nil,
          release: String.t() | nil,
          job_id: pos_integer() | nil,
          attempts: pos_integer() | nil
        }

  @callback trace_attributes(trace_context()) :: map()
  @callback turn_start_attributes(String.t()) :: map()
  @callback response_start_attributes(String.t()) :: map()
  @callback generation_start_attributes(
              String.t(),
              String.t() | nil,
              String.t() | nil,
              String.t() | nil
            ) :: map()
  @callback output_attributes(String.t()) :: map()
  @callback first_output_attributes() :: map()

  @spec values() :: [name()]
  def values, do: Enum.map(@providers, &elem(&1, 0))

  @spec fetch(name()) :: {:ok, implementation()} | :error
  def fetch(name) do
    case List.keyfind(@providers, name, 0) do
      {_name, provider} -> {:ok, provider}
      nil -> :error
    end
  end
end
