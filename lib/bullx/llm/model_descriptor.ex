defmodule BullX.LLM.ModelDescriptor do
  @moduledoc false

  alias BullX.LLM.ModelConfig

  @default_reasoning %{efforts: [:none]}

  @enforce_keys [:provider_id, :model]
  defstruct [
    :provider_id,
    :model,
    :label,
    :context_window,
    :max_completion_tokens,
    reasoning: @default_reasoning,
    source: :static
  ]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          model: String.t(),
          label: String.t() | nil,
          context_window: pos_integer() | nil,
          max_completion_tokens: pos_integer() | nil,
          reasoning: %{efforts: [atom()]},
          source: :static | :dynamic | :manual
        }

  @spec public(t()) :: map()
  def public(%__MODULE__{} = descriptor) do
    %{
      provider_id: descriptor.provider_id,
      model: descriptor.model,
      label: descriptor.label || descriptor.model,
      context_window: descriptor.context_window,
      fallback_context_window: ModelConfig.default_context_window(),
      max_completion_tokens: descriptor.max_completion_tokens,
      reasoning: %{
        efforts: Enum.map(descriptor.reasoning.efforts, &Atom.to_string/1)
      },
      source: Atom.to_string(descriptor.source)
    }
  end
end
