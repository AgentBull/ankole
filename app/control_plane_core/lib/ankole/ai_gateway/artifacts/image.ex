defmodule Ankole.AIGateway.Artifacts.Image do
  @moduledoc false

  alias Ankole.AIGateway.OpenAIError

  @spec decode_base64(term()) :: {:ok, binary()} | {:error, OpenAIError.t()}
  def decode_base64(value) when is_binary(value) do
    case Base.decode64(value) do
      {:ok, payload} ->
        {:ok, payload}

      :error ->
        {:error,
         OpenAIError.invalid("result", "invalid_base64", "Generated image was not valid base64.")}
    end
  end

  def decode_base64(_value),
    do:
      {:error,
       OpenAIError.invalid("result", "invalid_type", "Generated image result must be base64.")}

  @spec validate_generated_size(binary(), non_neg_integer()) :: :ok | {:error, OpenAIError.t()}
  def validate_generated_size(payload, max_bytes),
    do: validate_generated_byte_size(byte_size(payload), max_bytes)

  @spec validate_generated_byte_size(non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, OpenAIError.t()}
  def validate_generated_byte_size(byte_size, max_bytes) when byte_size <= max_bytes, do: :ok

  def validate_generated_byte_size(_byte_size, _max_bytes) do
    {:error,
     OpenAIError.invalid(
       "result",
       "response_too_large",
       "Generated image exceeds the 50 MiB limit."
     )}
  end

  @spec sniff(binary()) :: {:ok, String.t()} | {:error, OpenAIError.t()}
  def sniff(<<137, 80, 78, 71, 13, 10, 26, 10, _rest::binary>>), do: {:ok, "image/png"}
  def sniff(<<255, 216, 255, _rest::binary>>), do: {:ok, "image/jpeg"}
  def sniff(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: {:ok, "image/webp"}
  def sniff(<<"GIF87a", _rest::binary>>), do: {:ok, "image/gif"}
  def sniff(<<"GIF89a", _rest::binary>>), do: {:ok, "image/gif"}

  def sniff(_payload),
    do:
      {:error,
       OpenAIError.invalid("file", "invalid_image", "File content is not a supported image.")}

  @spec validate_declared_mime(String.t() | nil, String.t()) ::
          :ok | {:error, OpenAIError.t()}
  def validate_declared_mime(nil, _sniffed), do: :ok
  def validate_declared_mime("", _sniffed), do: :ok
  def validate_declared_mime(mime_type, mime_type), do: :ok

  def validate_declared_mime(_declared, _sniffed),
    do:
      {:error,
       OpenAIError.invalid(
         "result",
         "invalid_image",
         "Generated image MIME type does not match its content."
       )}
end
