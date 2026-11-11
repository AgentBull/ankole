defmodule Ankole.AIGateway.RequestParams do
  @moduledoc """
  Normalizes and validates the top-level parameter envelope for synchronous
  and asynchronous non-streaming AIGateway capability endpoints (`Audio`,
  `OCR`, `Decisions`, and `MediaJobs`).

  Every capability accepts `model`, optional `provider_options` (as an object),
  `stream: false` (dropped before provider dispatch), and internal
  `__ankole_*` envelope keys. Unknown top-level keys and `stream: true` are
  rejected upfront with `400 invalid_request_error` (`unsupported_parameter`),
  and optional `nil` fields are stripped unless explicitly listed in
  `:keep_nil`.
  """

  alias Ankole.AIGateway.OpenAIError
  alias Ankole.Attrs

  @envelope_keys ~w(model provider_options)

  @spec prepare(map(), [String.t()], keyword()) :: {:ok, map()} | {:error, OpenAIError.t()}
  def prepare(request, allowed_keys, opts \\ []) when is_map(request) and is_list(allowed_keys) do
    keep_nil = MapSet.new(Keyword.get(opts, :keep_nil, []))
    allowed = MapSet.new(allowed_keys ++ @envelope_keys)
    normalized = Attrs.normalize_external_attrs(request)

    with {:ok, normalized} <- validate_stream(normalized),
         :ok <- validate_known_keys(normalized, allowed),
         :ok <- validate_provider_options(Map.get(normalized, "provider_options")) do
      cleaned =
        Enum.reduce(normalized, %{}, fn {key, value}, acc ->
          if is_nil(value) and not MapSet.member?(keep_nil, key) do
            acc
          else
            Map.put(acc, key, value)
          end
        end)

      {:ok, cleaned}
    end
  end

  defp validate_stream(request) do
    case Map.pop(request, "stream", :absent) do
      {:absent, request} ->
        {:ok, request}

      {value, request} when value in [false, nil] ->
        {:ok, request}

      {true, _request} ->
        {:error,
         OpenAIError.invalid(
           "stream",
           "unsupported_parameter",
           "Streaming is not supported for this endpoint."
         )}

      {_invalid, _request} ->
        {:error,
         OpenAIError.invalid(
           "stream",
           "invalid_value",
           "stream must be false when provided."
         )}
    end
  end

  defp validate_known_keys(request, allowed) do
    unknown =
      request
      |> Map.keys()
      |> Enum.reject(fn key ->
        MapSet.member?(allowed, key) or String.starts_with?(key, "__ankole_")
      end)
      |> Enum.sort()

    case unknown do
      [] ->
        :ok

      [first | _rest] ->
        {:error,
         OpenAIError.invalid(
           first,
           "unsupported_parameter",
           "Unsupported parameter: #{first}."
         )}
    end
  end

  defp validate_provider_options(nil), do: :ok
  defp validate_provider_options(options) when is_map(options), do: :ok

  defp validate_provider_options(_options) do
    {:error,
     OpenAIError.invalid(
       "provider_options",
       "invalid_value",
       "provider_options must be an object."
     )}
  end
end
