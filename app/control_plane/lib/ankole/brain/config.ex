defmodule Ankole.Brain.Config do
  @moduledoc "Typed AppConfigure ownership for Brain runtime policy."

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.Principals
  alias Ankole.Principals.Principal
  alias Ankole.Repo

  @knowledge_key "brain.knowledge"
  @dreaming_key "brain.dreaming"
  @embedding_key "brain.embedding"
  @search_key "brain.search"
  @sources_key "brain.sources"

  @default_knowledge %{
    "pinned_memo_max_tokens" => 1_500,
    "result_limit" => 10
  }

  @default_dreaming %{
    "enabled" => nil,
    "material_limit" => 240,
    "token_limit" => 0,
    "mutation_limit" => 0,
    "curation_silence_minutes" => 30,
    "curation_backlog_rows" => 50,
    "episode_silence_minutes" => 30,
    "episode_backlog_rows" => 200,
    "episode_window_max_rows" => 200,
    "episode_window_max_tokens" => 8_000,
    "episode_tail_guard_rows" => 20,
    "episode_tail_guard_minutes" => 360,
    "episode_cold_start_lookback_days" => 5
  }

  @default_embedding %{
    "enabled" => false,
    "model_agent_uid" => nil,
    "dimensions" => nil
  }

  @default_search %{
    "half_life_days" => 30,
    "knowledge_decay_floor" => 0.5,
    "rerank_enabled" => false,
    "rerank_model_agent_uid" => nil
  }

  @default_sources %{
    "enabled" => true,
    "sync_interval_minutes" => 15,
    "block_max_tokens" => 1_500
  }

  @spec knowledge_definition() :: Definition.t()
  def knowledge_definition do
    AppConfigure.define(
      key: @knowledge_key,
      scope: :global,
      encrypted: false,
      schema: knowledge_schema(),
      default_value: @default_knowledge,
      description: "Long-term memory projection budget and maximum number of retrieval results."
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
      description: "Episode generation and Agent knowledge curation policy."
    )
  end

  @spec embedding_definition() :: Definition.t()
  def embedding_definition do
    AppConfigure.define(
      key: @embedding_key,
      scope: :global,
      encrypted: false,
      schema: embedding_schema(),
      default_value: @default_embedding,
      description: "Installation-wide embedding model owner and output dimensions."
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
      description: "Long-term memory decay and optional global reranking."
    )
  end

  @spec sources_definition() :: Definition.t()
  def sources_definition do
    AppConfigure.define(
      key: @sources_key,
      scope: :global,
      encrypted: false,
      schema: sources_schema(),
      default_value: @default_sources,
      description: "Retained external source synchronization policy."
    )
  end

  @spec definitions() :: [Definition.t()]
  def definitions do
    [
      knowledge_definition(),
      dreaming_definition(),
      embedding_definition(),
      search_definition(),
      sources_definition()
    ]
  end

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

  @spec embedding() :: {:ok, map()} | {:error, term()}
  def embedding, do: get(embedding_definition())

  @spec sources() :: {:ok, map()} | {:error, term()}
  def sources, do: get(sources_definition())

  @spec dreaming() :: {:ok, map()} | {:error, term()}
  def dreaming, do: get(dreaming_definition())

  @spec dreaming(String.t()) :: {:ok, map()} | {:error, term()}
  def dreaming(agent_uid) when is_binary(agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         :ok <- require_agent_principal(agent_uid),
         :ok <- ensure_registered(),
         {:ok, config} <- AppConfigure.get(dreaming_definition(), agent_id: agent_uid) do
      {:ok, Map.put(config, "enabled", effective_dreaming_enabled(config))}
    end
  end

  defp get(definition) do
    with :ok <- ensure_registered() do
      AppConfigure.get(definition)
    end
  end

  defp effective_dreaming_enabled(%{"enabled" => enabled}) when is_boolean(enabled), do: enabled
  defp effective_dreaming_enabled(_config), do: true

  defp require_agent_principal(uid) do
    case Repo.get(Principal, uid) do
      %Principal{type: :agent} -> :ok
      %Principal{} -> {:error, :brain_dreaming_requires_agent}
      nil -> {:error, :not_found}
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
             {:ok, material_limit} <- integer(value, "material_limit", 1, 10_000),
             {:ok, token_limit} <- integer(value, "token_limit", 0, 10_000_000),
             {:ok, mutation_limit} <- integer(value, "mutation_limit", 0, 100_000),
             {:ok, curation_silence_minutes} <-
               integer(value, "curation_silence_minutes", 0, 1_440),
             {:ok, curation_backlog_rows} <-
               integer(value, "curation_backlog_rows", 1, 10_000),
             {:ok, silence_minutes} <- integer(value, "episode_silence_minutes", 0, 1_440),
             {:ok, backlog_rows} <- integer(value, "episode_backlog_rows", 1, 10_000),
             {:ok, window_rows} <- integer(value, "episode_window_max_rows", 1, 500),
             {:ok, window_tokens} <-
               integer(value, "episode_window_max_tokens", 500, 200_000),
             {:ok, tail_rows} <- integer(value, "episode_tail_guard_rows", 0, 200),
             {:ok, tail_minutes} <- integer(value, "episode_tail_guard_minutes", 0, 1_440),
             # `nil` means no cold-start boundary: Stage A summarizes the full retained history of
             # a channel that has no cursor. A stored value that predates this setting reads as
             # `nil` and keeps that behaviour, because AppConfigure replaces the default with the
             # stored map instead of merging the two.
             {:ok, cold_start_lookback_days} <-
               optional_integer(value, "episode_cold_start_lookback_days", 0, 36_500) do
          {:ok,
           %{
             "enabled" => enabled,
             "material_limit" => material_limit,
             "token_limit" => token_limit,
             "mutation_limit" => mutation_limit,
             "curation_silence_minutes" => curation_silence_minutes,
             "curation_backlog_rows" => curation_backlog_rows,
             "episode_silence_minutes" => silence_minutes,
             "episode_backlog_rows" => backlog_rows,
             "episode_window_max_rows" => window_rows,
             "episode_window_max_tokens" => window_tokens,
             "episode_tail_guard_rows" => tail_rows,
             "episode_tail_guard_minutes" => tail_minutes,
             "episode_cold_start_lookback_days" => cold_start_lookback_days
           }}
        end

      _value ->
        {:error, :not_brain_dreaming_config}
    end)
  end

  defp embedding_schema do
    Schema.new(fn
      value when is_map(value) ->
        with {:ok, enabled} <- required_boolean(value, "enabled"),
             {:ok, model_agent_uid} <- optional_uid(value, "model_agent_uid"),
             {:ok, dimensions} <- optional_integer(value, "dimensions", 1, 4_096),
             :ok <- embedding_configuration_valid(enabled, model_agent_uid, dimensions) do
          {:ok,
           %{
             "enabled" => enabled,
             "model_agent_uid" => model_agent_uid,
             "dimensions" => dimensions
           }}
        end

      _value ->
        {:error, :not_brain_embedding_config}
    end)
  end

  defp search_schema do
    Schema.new(fn
      value when is_map(value) ->
        with {:ok, half_life_days} <- integer(value, "half_life_days", 0, 36_500),
             {:ok, knowledge_decay_floor} <-
               number(value, "knowledge_decay_floor", 0.0, 1.0),
             {:ok, rerank_enabled} <- required_boolean(value, "rerank_enabled"),
             {:ok, rerank_model_agent_uid} <- optional_uid(value, "rerank_model_agent_uid") do
          {:ok,
           %{
             "half_life_days" => half_life_days,
             "knowledge_decay_floor" => knowledge_decay_floor,
             "rerank_enabled" => rerank_enabled,
             "rerank_model_agent_uid" => rerank_model_agent_uid
           }}
        end

      _value ->
        {:error, :not_brain_search_config}
    end)
  end

  defp sources_schema do
    Schema.new(fn
      value when is_map(value) ->
        with {:ok, enabled} <- required_boolean(value, "enabled"),
             {:ok, sync_interval_minutes} <-
               integer(value, "sync_interval_minutes", 1, 10_080),
             {:ok, block_max_tokens} <- integer(value, "block_max_tokens", 100, 100_000) do
          {:ok,
           %{
             "enabled" => enabled,
             "sync_interval_minutes" => sync_interval_minutes,
             "block_max_tokens" => block_max_tokens
           }}
        end

      _value ->
        {:error, :not_brain_sources_config}
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

  defp optional_integer(value, key, min, max) do
    case Map.get(value, key) do
      nil -> {:ok, nil}
      number when is_integer(number) and number >= min and number <= max -> {:ok, number}
      _value -> {:error, {:invalid_integer, key, %{min: min, max: max}}}
    end
  end

  defp number(value, key, min, max) do
    case Map.fetch(value, key) do
      {:ok, number} when is_number(number) and number >= min and number <= max ->
        {:ok, number / 1}

      _value ->
        {:error, {:invalid_number, key, %{min: min, max: max}}}
    end
  end

  defp embedding_configuration_valid(false, _model_agent_uid, _dimensions), do: :ok

  defp embedding_configuration_valid(true, model_agent_uid, dimensions)
       when is_binary(model_agent_uid) and is_integer(dimensions),
       do: :ok

  defp embedding_configuration_valid(true, _model_agent_uid, _dimensions),
    do: {:error, :incomplete_embedding_configuration}

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
end
