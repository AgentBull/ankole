defmodule BullX.LLM.Spec do
  @moduledoc """
  Parses compact `provider:model` references used in config and setup payloads.

  The provider side must be a BullX logical provider id. The model side is left
  provider-defined because vendors use different model naming schemes and
  versions.
  """

  @provider_id_format ~r/^[a-z][a-z0-9_-]{0,62}$/

  @enforce_keys [:provider_id, :model_id]
  defstruct [:provider_id, :model_id]

  @type t :: %__MODULE__{provider_id: String.t(), model_id: String.t()}

  @spec parse(String.t()) :: {:ok, t()} | {:error, {:invalid_llm_spec, term()}}
  def parse(spec) when is_binary(spec) do
    case String.split(spec, ":", parts: 2) do
      [provider_id, model_id] ->
        validate_parts(provider_id, model_id)

      _other ->
        {:error, {:invalid_llm_spec, :missing_separator}}
    end
  end

  def parse(_spec), do: {:error, {:invalid_llm_spec, :not_string}}

  @spec parse!(String.t()) :: t() | no_return()
  def parse!(spec) do
    case parse(spec) do
      {:ok, parsed} ->
        parsed

      {:error, reason} ->
        raise ArgumentError, "invalid LLM spec #{inspect(spec)}: #{inspect(reason)}"
    end
  end

  defp validate_parts(provider_id, model_id) do
    cond do
      not Regex.match?(@provider_id_format, provider_id) ->
        {:error, {:invalid_llm_spec, :invalid_provider_id}}

      String.trim(model_id) == "" ->
        {:error, {:invalid_llm_spec, :missing_model_id}}

      true ->
        {:ok, %__MODULE__{provider_id: provider_id, model_id: model_id}}
    end
  end
end
