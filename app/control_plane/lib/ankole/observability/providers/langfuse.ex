defmodule Ankole.Observability.Providers.Langfuse do
  @moduledoc false

  @behaviour Ankole.Observability.Provider

  import Ankole.Observability.Trace, only: [maybe_put: 3]

  @impl true
  def trace_attributes(context) do
    %{"langfuse.trace.tags" => ["ankole", "ai_gateway"]}
    |> maybe_put("langfuse.trace.metadata.principal_uid", context.principal_uid)
    |> maybe_put("langfuse.trace.metadata.principal_type", context.principal_type)
    |> maybe_put("langfuse.trace.metadata.actor_event_id", context.actor_event_id)
    |> maybe_put("langfuse.trace.metadata.originator", context.originator)
    |> maybe_put("langfuse.trace.metadata.caller", context.caller)
    |> maybe_put("langfuse.trace.metadata.job_id", context.job_id)
    |> maybe_put("langfuse.trace.metadata.attempts", context.attempts)
    |> maybe_put("langfuse.release", context.release)
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
    |> maybe_put("langfuse.observation.model.name", model)
    |> maybe_put("langfuse.observation.model.parameters", model_parameters)
  end

  @impl true
  def output_attributes(output), do: %{"langfuse.observation.output" => output}

  @impl true
  def first_output_attributes do
    %{
      "langfuse.observation.completion_start_time" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
