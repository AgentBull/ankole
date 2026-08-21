defmodule Ankole.Observability.Providers.Langfuse do
  @moduledoc false

  @behaviour Ankole.Observability.Provider

  import Ankole.Observability.Trace, only: [put_present: 3]

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
  def output_attributes(output), do: %{"langfuse.observation.output" => output}

  @impl true
  def first_output_attributes do
    %{
      "langfuse.observation.completion_start_time" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
