defmodule Ankole.AIGateway.ProviderFailure do
  @moduledoc """
  One upstream failure at the native execution boundary.

  FailureDiagnostics owns its classification and public projection. The decoded
  provider body or normalized error facts stay internal and are never included
  in safe log fields.
  """

  defstruct [
    :kind,
    :code,
    :stage,
    :message,
    :provider_status,
    :provider_error_type,
    :retryable,
    provider_headers: [],
    provider_body: %{}
  ]

  @type t :: %__MODULE__{
          kind: :status_rejected | :invalid_response | :other,
          code: String.t() | nil,
          stage: String.t() | nil,
          message: String.t() | nil,
          provider_status: integer() | nil,
          provider_error_type: String.t() | nil,
          retryable: boolean() | nil,
          provider_headers: list(),
          provider_body: map()
        }

  @spec from_native(map()) :: t()
  def from_native(error) when is_map(error) do
    code = error["code"]
    stage = error["stage"]
    status = error["provider_status"]

    kind =
      cond do
        stage in ["hosted_responses", "image_generation"] ->
          :other

        code in ["provider_status_rejected", "websocket_status_rejected"] and is_integer(status) ->
          :status_rejected

        code == "invalid_upstream_response" and is_integer(status) ->
          :invalid_response

        true ->
          :other
      end

    %__MODULE__{
      kind: kind,
      code: code,
      stage: stage,
      provider_status: status,
      message: error["message"],
      provider_error_type: error["provider_error_type"],
      retryable: error["retryable"],
      provider_headers: headers(error["provider_headers"]),
      provider_body: body(error["provider_body_excerpt"])
    }
  end

  @spec from_event_error(map()) :: t()
  def from_event_error(error) when is_map(error) do
    classification =
      Ankole.AIGateway.FailureDiagnostics.classify({:provider_event_failed, error})

    details =
      case error["details_json"] do
        %{} = details -> details
        _ -> %{}
      end

    %__MODULE__{
      kind: :other,
      code: Map.get(error, "code", "provider_status_rejected"),
      stage: Map.get(details, "stage", "provider_response"),
      message: Map.get(error, "message", "provider request failed"),
      provider_error_type: classification[:provider_error_type],
      retryable: classification[:retryable],
      provider_status: classification[:provider_status],
      provider_headers: headers(details["provider_headers"]),
      provider_body:
        %{
          "code" => classification[:provider_error_code],
          "type" => classification[:provider_error_type],
          "message" => classification[:provider_message]
        }
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    }
  end

  defp body(excerpt) when is_binary(excerpt) do
    case Ankole.JSON.decode(excerpt) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"body" => decoded}
      {:error, _} -> %{"raw_body" => excerpt}
    end
  end

  defp body(_), do: %{}

  defp headers(value) when is_list(value) do
    Enum.flat_map(value, fn
      [name, value] when is_binary(name) and is_binary(value) -> [{name, value}]
      {name, value} when is_binary(name) and is_binary(value) -> [{name, value}]
      _ -> []
    end)
  end

  defp headers(value) when is_map(value), do: Enum.to_list(value)
  defp headers(_), do: []
end
