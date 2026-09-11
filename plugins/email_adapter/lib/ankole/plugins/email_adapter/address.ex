defmodule Ankole.Plugins.EmailAdapter.Address do
  @moduledoc false

  @address_format ~r/\A[^\s@<>,;"]+@[^\s@<>,;"]+\.[^\s@<>,;"]+\z/
  @loose_address ~r/[^\s<>,;"()]+@[^\s<>,;"()]+/

  @type mailbox :: %{address: String.t(), name: String.t() | nil}

  @doc "Lowercases and validates one bare address."
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(value) when is_binary(value) do
    candidate = value |> String.trim() |> String.trim_leading("<") |> String.trim_trailing(">")

    if Regex.match?(@address_format, candidate),
      do: {:ok, String.downcase(candidate)},
      else: :error
  end

  def normalize(_value), do: :error

  @doc """
  Parses one decoded address header into mailboxes.

  The RFC 5322 parser handles display names, groups, and comments. When it
  rejects a malformed header, the loose scan still recovers the bare addresses
  so a sloppy sender does not lose its message.
  """
  @spec parse_list(String.t() | nil) :: [mailbox()]
  def parse_list(nil), do: []

  def parse_list(value) when is_binary(value) do
    case safe_parse(value) do
      {:ok, mailboxes} when mailboxes != [] ->
        mailboxes

      _fallback ->
        @loose_address
        |> Regex.scan(value)
        |> Enum.map(&List.first/1)
        |> Enum.map(&%{address: &1, name: nil})
    end
    |> Enum.flat_map(fn %{address: address, name: name} ->
      case normalize(address) do
        {:ok, normalized} -> [%{address: normalized, name: presence(name)}]
        :error -> []
      end
    end)
    |> Enum.uniq_by(& &1.address)
  end

  @spec domain(String.t()) :: String.t() | nil
  def domain(address) when is_binary(address) do
    case String.split(address, "@", parts: 2) do
      [_local, domain] -> String.downcase(domain)
      _other -> nil
    end
  end

  @doc "Formats one mailbox for a header value; `mimemail` encodes non-ASCII names."
  @spec format(mailbox()) :: String.t()
  def format(%{address: address, name: name}) do
    case presence(name) do
      nil -> address
      name -> "#{quote_name(name)} <#{address}>"
    end
  end

  defp safe_parse(value) do
    case :smtp_util.parse_rfc5322_addresses(value) do
      {:ok, entries} ->
        {:ok,
         Enum.map(entries, fn {name, address} ->
           %{
             address: to_text(address),
             name: if(name == :undefined, do: nil, else: to_text(name))
           }
         end)}

      {:error, _reason} ->
        :error
    end
  rescue
    _exception -> :error
  catch
    _kind, _reason -> :error
  end

  defp to_text(value) when is_list(value), do: List.to_string(value)
  defp to_text(value) when is_binary(value), do: value
  defp to_text(_value), do: ""

  defp quote_name(name) do
    if Regex.match?(~r/\A[A-Za-z0-9 ._-]+\z/, name),
      do: name,
      else: "\"" <> String.replace(name, ~r/["\\]/, "") <> "\""
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
