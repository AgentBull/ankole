defmodule Ankole.Plugins.EmailAdapter.ReplyText do
  @moduledoc """
  Removes the quoted earlier messages from a reply body.

  The caller applies this only to a message that joined a mirrored thread,
  where the earlier messages are already stored and a full quoted thread would
  exhaust the inbound batch text budget. A forwarded message and the first
  message of a thread keep their complete body. The cut is a heuristic over
  the separator lines that common mail clients write for a reply.
  """

  @separators [
    ~r/\AOn .{1,200}wrote:\s*\z/,
    ~r/\A-{2,}\s*Original Message\s*-{2,}\z/i,
    ~r/\A-{2,}\s*原始邮件\s*-{2,}\z/u,
    ~r/\A在.{1,120}写道[:：]\s*\z/u,
    ~r/\A\d{4}[-\/年].{1,80}写道[:：]\s*\z/u,
    ~r/\A_{5,}\s*\z/,
    ~r/\A发件人[:：].+\z/u,
    ~r/\ASent from my .{1,40}\z/i
  ]

  # A forward marker above the first reply separator means the block below is
  # new content that the sender chose to pass on, not quoted history.
  @forward_markers [
    ~r/\A-{2,}\s*Forwarded message\s*-{2,}\z/i,
    ~r/\A-{2,}\s*转发的?邮件\s*-{2,}\z/u,
    ~r/\ABegin forwarded message:\s*\z/i
  ]

  @forward_subject ~r/\A\s*(fw|fwd|wg|tr|转发)\s*[:：]/iu

  @outlook_from ~r/\AFrom:\s.+\z/
  @outlook_follow ~r/\A(Sent|Date|To|Subject):\s/

  @doc "A subject with a forward prefix marks the whole body as forwarded content."
  @spec forwarded_subject?(String.t() | nil) :: boolean()
  def forwarded_subject?(nil), do: false
  def forwarded_subject?(subject), do: Regex.match?(@forward_subject, subject)

  @spec strip_quoted(String.t()) :: {String.t() | nil, boolean()}
  def strip_quoted(text) when is_binary(text) do
    lines = String.split(text, ~r/\r?\n/)

    case boundary(lines) do
      :forward -> {text, false}
      :none -> cut(lines, length(lines))
      {:cut, index} -> cut(lines, index)
    end
  end

  # Removes the lines below the cut and any quoted or blank tail above it.
  defp cut(lines, index) do
    kept =
      lines
      |> Enum.take(index)
      |> Enum.reverse()
      |> Enum.drop_while(&(quoted?(&1) or String.trim(&1) == ""))
      |> Enum.reverse()

    removed? = index < length(lines) or length(kept) < index

    case kept |> Enum.join("\n") |> String.trim() do
      "" -> {nil, removed?}
      result -> {result, removed?}
    end
  end

  # The first boundary line decides: a forward marker keeps the whole body,
  # a reply separator or an Outlook header block cuts below the text above it.
  defp boundary(lines) do
    lines
    |> Enum.with_index()
    |> Enum.find_value(:none, fn {line, index} ->
      trimmed = String.trim(line)

      cond do
        Enum.any?(@forward_markers, &Regex.match?(&1, trimmed)) -> :forward
        index == 0 -> nil
        Enum.any?(@separators, &Regex.match?(&1, trimmed)) -> {:cut, index}
        Regex.match?(@outlook_from, trimmed) and outlook_block?(lines, index) -> {:cut, index}
        true -> nil
      end
    end)
  end

  defp outlook_block?(lines, index) do
    lines
    |> Enum.slice(index + 1, 4)
    |> Enum.any?(&Regex.match?(@outlook_follow, String.trim(&1)))
  end

  defp quoted?(line), do: String.starts_with?(String.trim_leading(line), ">")
end
