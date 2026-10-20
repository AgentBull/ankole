defmodule Ankole.IdentityProviders.Phone do
  @moduledoc """
  Phone normalization for identity providers that accept Chinese national numbers.
  """

  alias Ankole.Kernel, as: NativeKernel

  @doc """
  Tries the supplied number, then adds +86 to an 11-digit number that starts with 1.

  Invalid numbers return `nil`. International numbers keep their country code.
  """
  @spec normalize_china_mobile(String.t() | nil) :: String.t() | nil
  def normalize_china_mobile(phone) do
    phone
    |> candidates()
    |> Enum.find_value(fn candidate ->
      case NativeKernel.phone_normalize_e164(candidate) do
        normalized when is_binary(normalized) -> normalized
        {:error, _reason} -> nil
      end
    end)
  end

  defp candidates(nil), do: []

  defp candidates(phone) when is_binary(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/\D/, "")

    case String.length(digits) == 11 and String.starts_with?(digits, "1") do
      true -> [trimmed, "+86" <> digits]
      false -> [trimmed]
    end
  end
end
