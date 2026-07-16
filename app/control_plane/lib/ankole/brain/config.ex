defmodule Ankole.Brain.Config do
  @moduledoc "Typed AppConfigure ownership for Brain runtime policy."

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @knowledge_key "brain.knowledge"
  @dreaming_key "brain.dreaming"
  @search_key "brain.search"

  @default_knowledge %{
    "pinned_memo_max_tokens" => 1_500,
    "result_limit" => 10
  }

  @default_dreaming %{
    "enabled" => nil,
    "model_agent_uid" => nil,
    "schedule_local_time" => "04:30",
    "material_limit" => 240,
    "token_limit" => 0,
    "mutation_limit" => 0,
    "episode_silence_minutes" => 30,
    "episode_backlog_rows" => 200,
    "episode_window_max_rows" => 200,
    "episode_window_max_tokens" => 8_000,
    "episode_tail_guard_rows" => 20,
    "episode_tail_guard_minutes" => 360
  }

  @default_search %{
    "half_life_days" => 30,
    "rerank_enabled" => false,
    "rerank_model_agent_uid" => nil
  }

  @spec knowledge_definition() :: Definition.t()
  def knowledge_definition do
    AppConfigure.define(
      key: @knowledge_key,
      scope: :global,
      encrypted: false,
      schema: knowledge_schema(),
      default_value: @default_knowledge,
      description: "Brain knowledge projection budget and maximum number of retrieval results."
    )
  end

  @spec dreaming_definition() :: Definition.t()
  def dreaming_definition do
    AppConfigure.define(
      key: @dreaming_key,
      scope: :scoped,
      encrypted: false,
      schema: dreaming_schema(),
      default_value: @default_dreaming,
      description:
        "Brain's only background process: channel episodes plus principal knowledge curation."
    )
  end

  @spec search_definition() :: Definition.t()
  def search_definition do
    AppConfigure.define(
      key: @search_key,
      scope: :global,
      encrypted: false,
      schema: search_schema(),
      default_value: @default_search,
      description: "Brain hybrid-search decay and optional reranking."
    )
  end

  @spec definitions() :: [Definition.t()]
  def definitions, do: [knowledge_definition(), dreaming_definition(), search_definition()]

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

  @spec knowledge() :: {:ok, map()} | {:error, term()}
  def knowledge, do: get(knowledge_definition())

  @spec search() :: {:ok, map()} | {:error, term()}
  def search, do: get(search_definition())

  @spec dreaming() :: {:ok, map()} | {:error, term()}
  def dreaming, do: get(dreaming_definition())

  @spec dreaming(String.t()) :: {:ok, map()} | {:error, term()}
  def dreaming(principal_uid) when is_binary(principal_uid) do
    with :ok <- ensure_registered(),
         {:ok, config} <- AppConfigure.get(dreaming_definition(), agent_id: principal_uid) do
      {:ok, Map.put(config, "enabled", effective_dreaming_enabled(config, principal_uid))}
    end
  end

  defp get(definition) do
    with :ok <- ensure_registered() do
      AppConfigure.get(definition)
    end
  end

  defp effective_dreaming_enabled(%{"enabled" => enabled}, _uid) when is_boolean(enabled),
    do: enabled

  defp effective_dreaming_enabled(_config, uid) do
    case Repo.get(Principal, String.downcase(uid)) do
      %Principal{type: :agent} -> true
      %Principal{} -> false
      nil -> false
    end
  end

  defp knowledge_schema do
    Schema.new(fn
      value when is_map(value) ->
        with {:ok, memo_tokens} <- integer(value, "pinned_memo_max_tokens", 1, 100_000),
             {:ok, result_limit} <- integer(value, "result_limit", 1, 100) do
          {:ok,
           %{
             "pinned_memo_max_tokens" => memo_tokens,
             "result_limit" => result_limit
           }}
        end

      _value ->
        {:error, :not_brain_knowledge_config}
    end)
  end

  defp dreaming_schema do
    Schema.new(fn
      value when is_map(value) ->
        with {:ok, enabled} <- optional_boolean(value, "enabled"),
             {:ok, model_agent_uid} <- optional_uid(value, "model_agent_uid"),
             {:ok, local_time} <- local_time(value, "schedule_local_time"),
             {:ok, material_limit} <- integer(value, "material_limit", 1, 10_000),
             {:ok, token_limit} <- integer(value, "token_limit", 0, 10_000_000),
             {:ok, mutation_limit} <- integer(value, "mutation_limit", 0, 100_000),
             {:ok, silence_minutes} <- integer(value, "episode_silence_minutes", 0, 1_440),
             {:ok, backlog_rows} <- integer(value, "episode_backlog_rows", 1, 10_000),
             {:ok, window_rows} <- integer(value, "episode_window_max_rows", 1, 500),
             {:ok, window_tokens} <-
               integer(value, "episode_window_max_tokens", 500, 200_000),
             {:ok, tail_rows} <- integer(value, "episode_tail_guard_rows", 0, 200),
             {:ok, tail_minutes} <- integer(value, "episode_tail_guard_minutes", 0, 1_440) do
          {:ok,
           %{
             "enabled" => enabled,
             "model_agent_uid" => model_agent_uid,
             "schedule_local_time" => local_time,
             "material_limit" => material_limit,
             "token_limit" => token_limit,
             "mutation_limit" => mutation_limit,
             "episode_silence_minutes" => silence_minutes,
             "episode_backlog_rows" => backlog_rows,
             "episode_window_max_rows" => window_rows,
             "episode_window_max_tokens" => window_tokens,
             "episode_tail_guard_rows" => tail_rows,
             "episode_tail_guard_minutes" => tail_minutes
           }}
        end

      _value ->
        {:error, :not_brain_dreaming_config}
    end)
  end

  defp search_schema do
    Schema.new(fn
      value when is_map(value) ->
        with {:ok, half_life_days} <- integer(value, "half_life_days", 0, 36_500),
             {:ok, rerank_enabled} <- required_boolean(value, "rerank_enabled"),
             {:ok, rerank_model_agent_uid} <- optional_uid(value, "rerank_model_agent_uid") do
          {:ok,
           %{
             "half_life_days" => half_life_days,
             "rerank_enabled" => rerank_enabled,
             "rerank_model_agent_uid" => rerank_model_agent_uid
           }}
        end

      _value ->
        {:error, :not_brain_search_config}
    end)
  end

  defp integer(value, key, min, max) do
    case Map.fetch(value, key) do
      {:ok, number} when is_integer(number) and number >= min and number <= max ->
        {:ok, number}

      _value ->
        {:error, {:invalid_integer, key, %{min: min, max: max}}}
    end
  end

  defp required_boolean(value, key) do
    case Map.fetch(value, key) do
      {:ok, boolean} when is_boolean(boolean) -> {:ok, boolean}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp optional_boolean(value, key) do
    case Map.get(value, key) do
      nil -> {:ok, nil}
      boolean when is_boolean(boolean) -> {:ok, boolean}
      _value -> {:error, {:invalid_boolean, key}}
    end
  end

  defp optional_uid(value, key) do
    case Map.get(value, key) do
      nil ->
        {:ok, nil}

      uid when is_binary(uid) ->
        case String.trim(uid) do
          "" -> {:ok, nil}
          uid -> {:ok, String.downcase(uid)}
        end

      _value ->
        {:error, {:invalid_uid, key}}
    end
  end

  defp local_time(value, key) do
    case Map.get(value, key) do
      <<hour::binary-size(2), ":", minute::binary-size(2)>> = text ->
        with {hour, ""} <- Integer.parse(hour),
             {minute, ""} <- Integer.parse(minute),
             {:ok, _time} <- Time.new(hour, minute, 0) do
          {:ok, text}
        else
          _invalid -> {:error, {:invalid_local_time, key}}
        end

      _value ->
        {:error, {:invalid_local_time, key}}
    end
  end
end
