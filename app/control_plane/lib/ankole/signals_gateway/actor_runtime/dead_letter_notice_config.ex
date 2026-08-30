defmodule Ankole.SignalsGateway.ActorRuntime.DeadLetterNoticeConfig do
  @moduledoc """
  AppConfigure policy for error details in dead-letter notices.

  Error details stay hidden by default because Signal channels can have a
  broader audience than the Ankole Console. When an operator enables the
  setting, the notice uses the existing bounded and redacted error preview.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @key "signals_gateway.show_dead_letter_error_details"

  @spec definition() :: Definition.t()
  def definition do
    AppConfigure.define(
      key: @key,
      scope: :global,
      encrypted: false,
      schema: Schema.boolean(),
      default_value: false,
      description:
        "When true, dead-letter notices sent to Signal channels include bounded, redacted Actor turn error details."
    )
  end

  @doc false
  @spec enabled_in_tx?(module()) :: boolean()
  def enabled_in_tx?(repo) do
    case AppConfigure.get_global_by_key_in_tx(repo, @key) do
      {:ok, true} -> true
      _result -> false
    end
  end
end
