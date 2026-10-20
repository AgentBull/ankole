defmodule Ankole.Pod.Applets.AI do
  @moduledoc "Stateless Applet text generation through the configured Agent's AIGateway profiles."

  alias Ankole.{AIGateway, Principals}
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ReasoningEffort
  alias Ankole.AIGateway.ResponseItems
  alias Ankole.Pod.Config

  def generate_text(options) do
    with {:ok, uid} <- configured_agent(),
         :ok <- profile(options["model"]),
         :ok <- prompt(options),
         {:ok, _effort} <- ReasoningEffort.normalize(options["effort"]),
         {:ok, %{body: body}} <-
           AIGateway.create_response(uid, request(options),
             subject_type: "agent",
             check_token_quota: false
           ),
         {:ok, reason} <- finish_reason(body) do
      usage = body["usage"] || %{}

      {:ok,
       %{
         text: output_text(body),
         finishReason: reason,
         usage: %{
           inputTokens: usage["input_tokens"] || 0,
           outputTokens: usage["output_tokens"] || 0
         }
       }}
    else
      {:error, reason} ->
        {:error,
         %{status: status(reason), code: code(reason), message: code(reason), details: nil}}
    end
  end

  defp configured_agent do
    with {:ok, uid} when is_binary(uid) <- Config.applet_ai_agent_uid(),
         {:ok, %{principal: %{status: :active}}} <- Principals.get_agent(uid),
         do: {:ok, uid},
         else: (_ -> {:error, :ai_not_configured})
  end

  defp profile(model) when is_binary(model) do
    if not String.contains?(model, "/") and
         ModelProfiles.profile_capability(model) == {:ok, "llm"},
       do: :ok,
       else: {:error, :invalid_model}
  end

  defp profile(_), do: {:error, :invalid_model}

  defp prompt(%{"prompt" => prompt} = options) when is_binary(prompt) do
    if is_nil(options["system"]) or is_binary(options["system"]),
      do: :ok,
      else: {:error, :invalid_request}
  end

  defp prompt(_), do: {:error, :invalid_request}

  defp request(options) do
    %{"model" => options["model"], "input" => options["prompt"], "store" => false}
    |> then(fn request ->
      if options["system"], do: Map.put(request, "instructions", options["system"]), else: request
    end)
    |> then(fn request ->
      if options["effort"],
        do: Map.put(request, "reasoning", %{"effort" => options["effort"]}),
        else: request
    end)
  end

  defp finish_reason(%{"status" => "completed"}), do: {:ok, "stop"}

  defp finish_reason(%{
         "status" => "incomplete",
         "incomplete_details" => %{"reason" => "max_output_tokens"}
       }),
       do: {:ok, "length"}

  defp finish_reason(_), do: {:error, :ai_unavailable}

  defp output_text(%{"output_text" => text}) when is_binary(text), do: text

  defp output_text(%{"output" => output}) when is_list(output) do
    output
    |> ResponseItems.message_content_parts()
    |> Enum.filter(&match?(%{"type" => "output_text"}, &1))
    |> ResponseItems.text_parts()
    |> Enum.join("")
  end

  defp output_text(_), do: ""

  defp code(reason) when reason in [:ai_not_configured, :invalid_model, :invalid_request],
    do: Atom.to_string(reason)

  defp code({:reasoning_effort, _}), do: "invalid_effort"

  defp code(%Ankole.AIGateway.ProviderFailure{
         provider_status: status,
         provider_body: %{"error" => %{"param" => param}}
       })
       when status in [400, 422] and
              param in ["reasoning.effort", "reasoning_effort", "reasoningEffort"],
       do: "invalid_effort"

  defp code({name, _})
       when name in [
              :unknown_model_selector,
              :model_profile_not_configured,
              :invalid_model_profile,
              :model_profile_capability_mismatch
            ],
       do: "invalid_model"

  defp code(reason) when reason in [:model_profile_not_configured, :invalid_model_profile],
    do: "invalid_model"

  defp code(_), do: "ai_unavailable"

  defp status(reason),
    do:
      if(code(reason) == "ai_unavailable",
        do: 502,
        else: if(code(reason) == "invalid_request", do: 400, else: 422)
      )
end
