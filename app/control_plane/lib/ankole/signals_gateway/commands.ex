defmodule Ankole.SignalsGateway.Commands do
  @moduledoc """
  Visible text command parser for signal entries.
  """

  @commands MapSet.new(["new", "compress", "retry", "steer", "stop"])

  @doc """
  Classifies recognized visible slash commands.
  """
  @spec classify(String.t() | nil, keyword()) :: {:ok, map()} | :not_command
  def classify(text, opts \\ [])
  def classify(nil, _opts), do: :not_command

  def classify(text, opts) when is_binary(text) do
    text
    |> maybe_strip_leading_mention(opts)
    |> normalize_command_text()
    |> parse_normalized(text)
  end

  defp maybe_strip_leading_mention(text, opts) do
    prefixes = Keyword.get(opts, :structured_mention_prefixes, [])

    case Keyword.get(opts, :strip_leading_structured_mention, false) do
      true -> strip_one_prefix(text, prefixes)
      false -> text
    end
  end

  defp strip_one_prefix(text, prefixes) do
    Enum.reduce_while(prefixes, text, fn prefix, acc ->
      case String.starts_with?(acc, prefix) do
        true -> {:halt, acc |> String.replace_prefix(prefix, "") |> String.trim_leading()}
        false -> {:cont, acc}
      end
    end)
  end

  defp normalize_command_text(text) do
    text
    |> String.trim_leading()
    |> String.replace("\u3000", " ")
    |> normalize_full_width_digits()
  end

  defp normalize_full_width_digits(text) do
    text
    |> String.graphemes()
    |> Enum.map(&normalize_full_width_digit/1)
    |> IO.iodata_to_binary()
  end

  defp normalize_full_width_digit("０"), do: "0"
  defp normalize_full_width_digit("１"), do: "1"
  defp normalize_full_width_digit("２"), do: "2"
  defp normalize_full_width_digit("３"), do: "3"
  defp normalize_full_width_digit("４"), do: "4"
  defp normalize_full_width_digit("５"), do: "5"
  defp normalize_full_width_digit("６"), do: "6"
  defp normalize_full_width_digit("７"), do: "7"
  defp normalize_full_width_digit("８"), do: "8"
  defp normalize_full_width_digit("９"), do: "9"
  defp normalize_full_width_digit(grapheme), do: grapheme

  defp parse_normalized("/" <> rest, raw) do
    {name, args_text} =
      rest
      |> String.split([" ", "\n", "\t"], parts: 2)
      |> command_parts()

    case MapSet.member?(@commands, name) do
      true ->
        {:ok,
         %{
           "name" => name,
           "raw" => raw,
           "argsText" => args_text,
           "status" => "stub"
         }}

      false ->
        :not_command
    end
  end

  defp parse_normalized(_text, _raw), do: :not_command

  defp command_parts([name]), do: {String.downcase(name), ""}

  defp command_parts([name, args_text]),
    do: {String.downcase(name), String.trim_leading(args_text)}
end
