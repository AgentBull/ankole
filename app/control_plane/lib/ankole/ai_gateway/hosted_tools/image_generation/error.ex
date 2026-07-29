defmodule Ankole.AIGateway.HostedTools.ImageGeneration.Error do
  @moduledoc false

  alias Ankole.AIGateway.OpenAIError

  @image_user_error_codes ~w(
    content_policy_violation image_generation_user_error image_too_large image_too_small
    invalid_image unsupported_image_format image_not_found image_download_failed refusal
    moderation_blocked
  )

  @spec normalize_persistence(term()) :: OpenAIError.t()
  def normalize_persistence(%OpenAIError{code: "response_too_large"}) do
    OpenAIError.server(
      502,
      "response_too_large",
      "The generated image exceeded the response size limit."
    )
  end

  def normalize_persistence(%OpenAIError{code: code})
      when code in ["invalid_base64", "invalid_type", "invalid_image"] do
    OpenAIError.server(
      502,
      "upstream_error",
      "The image generation provider returned an invalid image."
    )
  end

  def normalize_persistence(:missing_completed_image_bytes) do
    OpenAIError.server(
      502,
      "upstream_error",
      "The image generation provider completed without final image bytes."
    )
  end

  def normalize_persistence(:unpersisted_completed_image) do
    OpenAIError.server(
      502,
      "upstream_error",
      "The image generation provider returned an invalid image completion."
    )
  end

  def normalize_persistence(:invalid_completed_image) do
    OpenAIError.server(
      502,
      "upstream_error",
      "The image generation provider returned an invalid completed image."
    )
  end

  def normalize_persistence(_reason) do
    OpenAIError.server(
      500,
      "artifact_persistence_failed",
      "The generated image could not be persisted."
    )
  end

  @spec normalize_execution(term()) :: OpenAIError.t()
  def normalize_execution(%OpenAIError{} = error), do: error

  def normalize_execution({:upstream_response_failed, status, body, _headers}),
    do: normalize_execution({:upstream_response_failed, status, body})

  def normalize_execution({:upstream_response_failed, 429, _body}), do: rate_limit()

  def normalize_execution({:upstream_response_failed, status, body})
      when status in [400, 422] do
    case image_user_error_code(body) do
      nil ->
        OpenAIError.server(
          502,
          "upstream_error",
          "The image generation provider rejected the request."
        )

      code ->
        OpenAIError.image_generation_user(code)
    end
  end

  def normalize_execution({:upstream_response_failed, status, _body})
      when status in [408, 504],
      do: timeout()

  def normalize_execution({:upstream_response_failed, _status, _body}) do
    OpenAIError.server(502, "upstream_error", "The image generation provider request failed.")
  end

  def normalize_execution({:universal_ai_request_failed, %{"code" => code}})
      when code in ["first_byte_timeout", "idle_timeout", "total_timeout"],
      do: timeout()

  def normalize_execution({:universal_ai_request_failed, %{"provider_status" => 429}}),
    do: rate_limit()

  def normalize_execution({:universal_ai_request_failed, %{"code" => code}})
      when code in @image_user_error_codes,
      do: OpenAIError.image_generation_user(code)

  def normalize_execution({:universal_ai_request_failed, %{"code" => code}})
      when code in [
             "response_body_too_large",
             "sse_event_too_large",
             "eventstream_frame_too_large",
             "websocket_message_too_large"
           ] do
    OpenAIError.server(502, "response_too_large", "The generated response exceeded 128 MiB.")
  end

  def normalize_execution(_reason) do
    OpenAIError.server(502, "upstream_error", "The hosted image generation request failed.")
  end

  defp image_user_error_code(body) when is_map(body) do
    code =
      get_in(body, ["error", "code"]) || Map.get(body, "code") ||
        get_in(body, ["error", "type"]) || Map.get(body, "error_type")

    if code in @image_user_error_codes, do: code
  end

  defp image_user_error_code(_body), do: nil

  defp rate_limit do
    OpenAIError.server(
      429,
      "rate_limit_exceeded",
      "The image generation provider rate limit was exceeded.",
      "rate_limit_error"
    )
  end

  defp timeout do
    OpenAIError.server(504, "upstream_timeout", "The image generation provider timed out.")
  end
end
