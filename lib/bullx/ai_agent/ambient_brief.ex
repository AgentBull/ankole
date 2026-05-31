defmodule BullX.AIAgent.AmbientBrief do
  @moduledoc """
  Generates compact recall text for long ambient observations.

  Ambient transcript items can be useful later without deserving immediate
  Agent intervention. This helper stores a bounded factual brief in message
  metadata so later context retrieval can carry the observation cheaply.
  """

  alias BullX.AIAgent.{Conversations, Message, Profile}
  alias BullX.LLM

  @threshold_chars 1_000
  @max_words 200

  @spec maybe_generate(Message.t(), Profile.t()) :: {:ok, Message.t()} | {:error, term()}
  def maybe_generate(%Message{role: :im_ambient, kind: :normal} = message, %Profile{} = profile) do
    text = text_content(message)

    case String.length(text) > @threshold_chars do
      true -> generate(message, profile, text)
      false -> {:ok, message}
    end
  end

  def maybe_generate(%Message{} = message, %Profile{}), do: {:ok, message}

  defp generate(message, profile, text) do
    prompt =
      [
        "Write a brief of at most 200 words for this observed group message. ",
        "Keep only safe facts useful for later context. Do not add unsupported details.\n\n",
        text
      ]
      |> IO.iodata_to_binary()

    case LLM.chat(
           profile.compression_llm,
           [%ReqLLM.Message{role: :user, content: [ReqLLM.Message.ContentPart.text(prompt)]}],
           tools: []
         ) do
      {:ok, result} ->
        brief = result.text |> String.trim() |> truncate_words(@max_words)

        case brief do
          "" ->
            {:ok, message}

          _brief ->
            metadata =
              message.metadata
              |> Map.put("brief", brief)
              |> Map.put("brief_usage", %{
                "usage" => result.usage,
                "usage_source" =>
                  if(is_nil(result.usage), do: "estimated", else: "provider_reported"),
                "provider_id" => result.provider_id,
                "model_id" => result.model_id
              })

            Conversations.update_message(message, %{metadata: metadata})
        end

      {:error, reason} ->
        :telemetry.execute([:bullx, :ai_agent, :ambient_brief, :error], %{}, %{
          reason: safe_reason(reason),
          message_id: message.id
        })

        {:ok, message}
    end
  end

  defp text_content(%Message{content: content}) do
    content
    |> Enum.filter(&(Map.get(&1, "type") == "text"))
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  defp truncate_words(text, max_words) do
    words = String.split(text, ~r/\s+/, trim: true)

    case length(words) > max_words do
      true -> words |> Enum.take(max_words) |> Enum.join(" ")
      false -> text
    end
  end

  defp safe_reason(reason) when is_atom(reason), do: reason
  defp safe_reason(_reason), do: :error
end
