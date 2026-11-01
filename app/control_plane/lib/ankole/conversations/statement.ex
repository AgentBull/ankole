defmodule Ankole.Conversations.Statement do
  @moduledoc "An Agent reply or notice with its source and rendering facts."
  @enforce_keys [:signal]
  defstruct [:signal, :completion, :outcome, :text, :notice, :now]

  def text(%__MODULE__{completion: %{final_text: text} = completion}) do
    prompt = Map.get(completion, :clarify_prompt) || Map.get(completion, :action_card_prompt)

    case prompt do
      %{"fallback_visible_text" => fallback} ->
        if text in [nil, ""], do: fallback, else: text <> "\n\n" <> fallback

      _ ->
        text
    end
  end

  def text(%__MODULE__{text: text}), do: text
end
