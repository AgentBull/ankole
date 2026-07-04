defmodule Ankole.Memory.Config do
  @moduledoc """
  AppConfigure definitions for Memory.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema

  @notes_key "memory.notes"
  @recall_key "memory.recall"

  @default_notes %{
    "enabled" => true,
    "max_notes_per_channel" => 40,
    "max_content_chars" => 500
  }

  @default_recall %{
    "enabled" => false,
    "model_agent_uid" => nil,
    "default_limit" => 5,
    "max_limit" => 10,
    "hot_context_hours" => 2,
    "hot_context_entries" => 80,
    "episode_silence_minutes" => 30,
    "episode_backlog_rows" => 200,
    "episode_window_max_rows" => 200,
    "episode_window_max_tokens" => 8_000,
    "episode_tail_guard_rows" => 20,
    "episode_tail_guard_minutes" => 360
  }

  @spec notes_definition() :: Definition.t()
  def notes_definition do
    AppConfigure.define(
      key: @notes_key,
      scope: :scoped,
      encrypted: false,
      schema: notes_schema(),
      default_value: @default_notes,
      description:
        "Layer A curated memory-note settings. Notes are current-channel scoped and capped to prevent prompt rot."
    )
  end

  @spec recall_definition() :: Definition.t()
  def recall_definition do
    AppConfigure.define(
      key: @recall_key,
      scope: :global,
      encrypted: false,
      schema: recall_schema(),
      default_value: @default_recall,
      description:
        "Layer B historical recall settings. Phase 2 requires memory.recall.model_agent_uid with light and embedding model profiles."
    )
  end

  @spec definitions() :: [Definition.t()]
  def definitions, do: [notes_definition(), recall_definition()]

  @spec ensure_registered() :: :ok | {:error, term()}
  def ensure_registered do
    Enum.reduce_while(definitions(), :ok, fn definition, :ok ->
      case AppConfigure.register_definitions([definition]) do
        :ok -> {:cont, :ok}
        {:error, {:duplicate_key, _key}} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec notes(String.t()) :: {:ok, map()} | {:error, term()}
  def notes(agent_uid) when is_binary(agent_uid) do
    with :ok <- ensure_registered() do
      AppConfigure.get(notes_definition(), agent_id: agent_uid)
    end
  end

  @spec recall() :: {:ok, map()} | {:error, term()}
  def recall do
    with :ok <- ensure_registered() do
      AppConfigure.get(recall_definition())
    end
  end

  defp notes_schema do
    Schema.new(fn
      value when is_map(value) ->
        with {:ok, enabled} <- required_boolean(value, "enabled"),
             {:ok, max_notes} <- bounded_integer(value, "max_notes_per_channel", 1, 40),
             {:ok, max_chars} <- bounded_integer(value, "max_content_chars", 1, 500) do
          {:ok,
           %{
             "enabled" => enabled,
             "max_notes_per_channel" => max_notes,
             "max_content_chars" => max_chars
           }}
        end

      _value ->
        {:error, :not_memory_notes_config}
    end)
  end

  defp recall_schema do
    Schema.new(fn
      value when is_map(value) ->
        with {:ok, enabled} <- required_boolean(value, "enabled"),
             {:ok, model_agent_uid} <- optional_uid(value, "model_agent_uid"),
             {:ok, default_limit} <- bounded_integer(value, "default_limit", 1, 10),
             {:ok, max_limit} <- bounded_integer(value, "max_limit", default_limit, 10),
             {:ok, hot_hours} <- bounded_integer(value, "hot_context_hours", 0, 24),
             {:ok, hot_entries} <- bounded_integer(value, "hot_context_entries", 0, 500),
             {:ok, silence_minutes} <-
               bounded_integer(value, "episode_silence_minutes", 0, 24 * 60),
             {:ok, backlog_rows} <- bounded_integer(value, "episode_backlog_rows", 1, 10_000),
             {:ok, max_rows} <- bounded_integer(value, "episode_window_max_rows", 1, 500),
             {:ok, max_tokens} <-
               bounded_integer(value, "episode_window_max_tokens", 500, 200_000),
             {:ok, tail_rows} <- bounded_integer(value, "episode_tail_guard_rows", 0, 200),
             {:ok, tail_minutes} <-
               bounded_integer(value, "episode_tail_guard_minutes", 0, 24 * 60) do
          {:ok,
           %{
             "enabled" => enabled,
             "model_agent_uid" => model_agent_uid,
             "default_limit" => default_limit,
             "max_limit" => max_limit,
             "hot_context_hours" => hot_hours,
             "hot_context_entries" => hot_entries,
             "episode_silence_minutes" => silence_minutes,
             "episode_backlog_rows" => backlog_rows,
             "episode_window_max_rows" => max_rows,
             "episode_window_max_tokens" => max_tokens,
             "episode_tail_guard_rows" => tail_rows,
             "episode_tail_guard_minutes" => tail_minutes
           }}
        end

      _value ->
        {:error, :not_memory_recall_config}
    end)
  end

  defp required_boolean(value, key) do
    case Map.fetch(value, key) do
      {:ok, flag} when is_boolean(flag) -> {:ok, flag}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp bounded_integer(value, key, min, max) do
    case Map.fetch(value, key) do
      {:ok, number} when is_integer(number) and number >= min and number <= max ->
        {:ok, number}

      _value ->
        {:error, {:invalid_integer, key, %{min: min, max: max}}}
    end
  end

  defp optional_uid(value, key) do
    case Map.get(value, key) do
      nil ->
        {:ok, nil}

      uid when is_binary(uid) ->
        case String.downcase(String.trim(uid)) do
          "" -> {:ok, nil}
          normalized -> {:ok, normalized}
        end

      _value ->
        {:error, {:invalid_uid, key}}
    end
  end
end
