defmodule Ankole.Observability.Providers.LangSmith do
  @moduledoc false

  @behaviour Ankole.Observability.Provider

  import Ankole.Observability.Trace, only: [put_present: 3]

  alias Ankole.Observability.WorkerOTLP

  @impl true
  def trace_attributes(context) do
    %{}
    |> put_present("langsmith.metadata.user_id", context.user_id)
    |> put_present("langsmith.trace.session_id", context.session_id)
  end

  @impl true
  def turn_start_attributes(input) do
    %{
      "langsmith.span.kind" => "chain",
      "gen_ai.prompt" => input
    }
  end

  @impl true
  def response_start_attributes(input) do
    %{
      "langsmith.span.kind" => "chain",
      "gen_ai.prompt" => input
    }
  end

  @impl true
  def generation_start_attributes(input, _model, _model_parameters, provider_name) do
    %{
      "langsmith.span.kind" => "llm",
      "gen_ai.prompt" => input
    }
    |> put_present("gen_ai.system", provider_name)
  end

  @impl true
  def output_attributes(output, _observation), do: %{"gen_ai.completion" => output}

  @impl true
  def first_output_attributes, do: %{}

  @impl true
  def map_worker_spans(payload) do
    WorkerOTLP.map_span_attributes(payload, &worker_span_attribute_patch/1)
  end

  defp worker_span_attribute_patch(attributes) do
    case Map.get(attributes, "gen_ai.operation.name") do
      "invoke_agent" ->
        observation_patch(attributes, "chain", "ankole.agent.input", "ankole.agent.output")

      "execute_tool" ->
        observation_patch(
          attributes,
          "tool",
          "gen_ai.tool.call.arguments",
          "gen_ai.tool.call.result"
        )

      _operation ->
        %{put: %{}, drop: []}
    end
  end

  defp observation_patch(attributes, kind, input_key, output_key) do
    put =
      %{"langsmith.span.kind" => kind}
      |> put_attribute("gen_ai.prompt", Map.get(attributes, input_key))
      |> put_attribute("gen_ai.completion", Map.get(attributes, output_key))

    %{put: put, drop: [input_key, output_key]}
  end

  defp put_attribute(attributes, key, value) when is_binary(value),
    do: Map.put(attributes, key, value)

  defp put_attribute(attributes, _key, _value), do: attributes
end
