defmodule Ankole.Sessions.Prompt.Delimiters do
  @moduledoc """
  Owns the boundaries of quoted conversation, event, environment, and memory data.

  Each caller keeps its trust policy. Context and event data replace their
  reserved tags; environment and memory data escape theirs. Environment facts
  also keep one line per field.
  """

  @context "conversation_context"
  @event "external_event"
  @environment "agent_environment_info"
  @memory "recalled_memory"
  @context_tags Regex.compile!("<\\s*\\/?\\s*(?:#{@context}|#{@environment})\\s*>", "iu")
  @event_tags Regex.compile!("<\\s*\\/?\\s*(?:#{@event}|#{@environment})\\s*>", "iu")
  @environment_tags Regex.compile!("<\\s*\\/?\\s*#{@environment}\\s*>", "iu")
  @memory_tags Regex.compile!("<\\s*\\/?\\s*(?:#{@memory}|#{@environment})\\s*>", "iu")

  def opening(:context), do: "<#{@context}>"
  def opening(:event), do: "<#{@event}>"
  def opening(:environment), do: "<#{@environment}>"
  def opening(:memory), do: "<#{@memory}>"

  def closing(:context), do: "</#{@context}>"
  def closing(:event), do: "</#{@event}>"
  def closing(:environment), do: "</#{@environment}>"
  def closing(:memory), do: "</#{@memory}>"

  def wrap(kind, text), do: opening(kind) <> "\n" <> text <> "\n" <> closing(kind)

  def quoted_context(text), do: String.replace(text, @context_tags, "[context delimiter]")
  def external_event(text), do: String.replace(text, @event_tags, "[event delimiter]")

  def environment_line(text) do
    text
    |> escape(@environment_tags)
    |> single_line()
    |> String.trim()
  end

  def recalled_memory(text), do: escape(text, @memory_tags)
  def memory_pointer(text), do: text |> recalled_memory() |> single_line()

  defp escape(text, tags) do
    Regex.replace(tags, text, fn tag ->
      tag |> String.replace("<", "&lt;") |> String.replace(">", "&gt;")
    end)
  end

  defp single_line(text), do: String.replace(text, ~r/[\r\n\x{2028}\x{2029}]+/u, " ")
end
