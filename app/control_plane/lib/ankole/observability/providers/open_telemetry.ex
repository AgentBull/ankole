defmodule Ankole.Observability.Providers.OpenTelemetry do
  @moduledoc false

  @behaviour Ankole.Observability.Provider

  @impl true
  def trace_attributes(_context), do: %{}

  @impl true
  def turn_start_attributes(input), do: %{"ankole.turn.input" => input}

  @impl true
  def response_start_attributes(input), do: %{"ankole.ai_gateway.input" => input}

  @impl true
  def generation_start_attributes(input, _model, _model_parameters, _provider_name),
    do: %{"ankole.ai_gateway.input" => input}

  @impl true
  def output_attributes(output, :turn), do: %{"ankole.turn.output" => output}

  def output_attributes(output, observation) when observation in [:response, :generation],
    do: %{"ankole.ai_gateway.output" => output}

  @impl true
  def first_output_attributes, do: %{}

  @impl true
  def map_worker_spans(payload), do: {:ok, payload}
end
