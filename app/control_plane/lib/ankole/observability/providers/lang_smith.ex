defmodule Ankole.Observability.Providers.LangSmith do
  @moduledoc false

  @behaviour Ankole.Observability.Provider

  import Ankole.Observability.Trace, only: [put_present: 3]

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
  def output_attributes(output), do: %{"gen_ai.completion" => output}

  @impl true
  def first_output_attributes, do: %{}
end
