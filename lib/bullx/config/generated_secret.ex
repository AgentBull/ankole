defmodule BullX.Config.GeneratedSecret do
  @moduledoc """
  Skogsra type and creation helper for BullX-created verification secrets.

  `type: :generated_secret` means BullX owns value generation. It is separate
  from `secret: true`, which controls encryption and redaction.
  """

  use Skogsra.Type

  @default_entropy_bits 256
  @min_encoded_length 43
  @url_safe_chars ~r/\A[A-Za-z0-9_-]+\z/

  @spec generate(keyword()) :: String.t()
  def generate(opts \\ []) do
    opts
    |> entropy_bits()
    |> random_bytes()
    |> Base.url_encode64(padding: false)
  end

  @impl Skogsra.Type
  def cast(value) when is_binary(value) do
    case generated_secret?(value) do
      true -> {:ok, value}
      false -> :error
    end
  end

  def cast(_value), do: :error

  defp entropy_bits(opts) do
    opts
    |> Keyword.get(:entropy_bits, @default_entropy_bits)
    |> validate_entropy_bits()
  end

  defp validate_entropy_bits(bits) when is_integer(bits) and bits >= @default_entropy_bits do
    bits
  end

  defp validate_entropy_bits(bits) do
    raise ArgumentError,
          "generated secret entropy_bits must be an integer >= #{@default_entropy_bits}, got: #{inspect(bits)}"
  end

  defp random_bytes(entropy_bits) do
    entropy_bits
    |> bytes_for_bits()
    |> :crypto.strong_rand_bytes()
  end

  defp bytes_for_bits(entropy_bits), do: div(entropy_bits + 7, 8)

  defp generated_secret?(value) do
    String.length(value) >= @min_encoded_length and Regex.match?(@url_safe_chars, value)
  end
end
