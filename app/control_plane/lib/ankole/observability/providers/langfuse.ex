defmodule Ankole.Observability.Providers.Langfuse do
  @moduledoc false

  @behaviour Ankole.Observability.Provider

  import Ankole.Observability.Trace, only: [put_present: 3]

  alias Ankole.Observability.WorkerOTLP

  @impl true
  def trace_attributes(context) do
    %{"langfuse.trace.tags" => ["ankole", "ai_gateway"]}
    |> put_present("langfuse.trace.metadata.principal_uid", context.principal_uid)
    |> put_present("langfuse.trace.metadata.principal_type", context.principal_type)
    |> put_present("langfuse.trace.metadata.actor_event_id", context.actor_event_id)
    |> put_present("langfuse.trace.metadata.originator", context.originator)
    |> put_present("langfuse.trace.metadata.caller", context.caller)
    |> put_present("langfuse.trace.metadata.job_id", context.job_id)
    |> put_present("langfuse.trace.metadata.attempts", context.attempts)
    |> put_present("langfuse.release", context.release)
  end

  @impl true
  def turn_start_attributes(input) do
    %{
      "langfuse.observation.type" => "agent",
      "langfuse.observation.input" => input
    }
  end

  @impl true
  def response_start_attributes(input) do
    %{
      "langfuse.observation.type" => "span",
      "langfuse.observation.input" => input
    }
  end

  @impl true
  def generation_start_attributes(input, model, model_parameters, _provider_name) do
    %{
      "langfuse.observation.type" => "generation",
      "langfuse.observation.input" => input
    }
    |> put_present("langfuse.observation.model.name", model)
    |> put_present("langfuse.observation.model.parameters", model_parameters)
  end

  @impl true
  def output_attributes(output, _observation), do: %{"langfuse.observation.output" => output}

  @impl true
  def first_output_attributes do
    %{
      "langfuse.observation.completion_start_time" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  @impl true
  def map_worker_spans(payload) do
    WorkerOTLP.map_span_attributes(payload, &worker_span_attribute_patch/1)
  end

  defp worker_span_attribute_patch(attributes) do
    case Map.get(attributes, "gen_ai.operation.name") do
      "invoke_agent" ->
        observation_patch(attributes, "agent", "ankole.agent.input", "ankole.agent.output")

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

  defp observation_patch(attributes, type, input_key, output_key) do
    put =
      %{"langfuse.observation.type" => type}
      |> put_attribute(
        "langfuse.observation.input",
        Map.get(attributes, input_key)
      )
      |> put_attribute(
        "langfuse.observation.output",
        Map.get(attributes, output_key)
      )

    %{put: put, drop: [input_key, output_key]}
  end

  defp put_attribute(attributes, key, value) when is_binary(value),
    do: Map.put(attributes, key, value)

  defp put_attribute(attributes, _key, _value), do: attributes
end
