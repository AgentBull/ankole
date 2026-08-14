defmodule Ankole.Observability.Providers.OpenTelemetry do
  @moduledoc false

  @behaviour Ankole.Observability.Provider

  @impl true
  def trace_attributes(_context), do: %{}

  @impl true
  def turn_start_attributes(_input), do: %{}

  @impl true
  def response_start_attributes(_input), do: %{}

  @impl true
  def generation_start_attributes(_input, _model, _model_parameters, _provider_name), do: %{}

  @impl true
  def output_attributes(_output), do: %{}

  @impl true
  def first_output_attributes, do: %{}
end
