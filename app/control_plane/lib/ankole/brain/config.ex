defmodule Ankole.Brain.Config do
  @moduledoc """
  AppConfigure declarations and typed reads for the `brain.*` key group.

  Brain models are instance-global: learning is a system activity of the
  instance knowledge space, not a per-Agent call. Agent model profiles serve
  only the Agent's own conversations, so no `brain.*` key is Agent-scoped.
  """

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.Logging

  @enabled_key "brain.enabled"
  @embedding_model_key "brain.embedding_model"
  @rerank_model_key "brain.rerank_model"
  @web_fetch_model_key "brain.web_fetch_model"
  @extraction_model_key "brain.extraction_model"
  @dreaming_model_key "brain.dreaming_model"
  @search_tokenizer_key "brain.search_tokenizer"
  @chunking_key "brain.chunking"
  @forgetting_key "brain.forgetting"
  @dreaming_task_cron_key "brain.dreaming_task_cron"
  @self_healing_task_cron_key "brain.self_healing_task_cron"
  @signal_channel_batch_idle_time_key "brain.signal_channel_batch_idle_time"
  @skill_learning_enabled_key "brain.skill_learning_enabled"
  @skill_learning_reflection_threshold_key "brain.skill_learning_reflection_threshold"

  @search_tokenizers ~w(icu jieba lindera_japanese lindera_korean)

  # The vector column is fixed at vector(4096); shorter embeddings are
  # zero-padded and larger models are rejected at configuration time.
  @max_embedding_dimensions 4096

  @chunking_defaults %{
    "chunk_size" => 300,
    "chunk_overlap" => 50,
    "max_chars" => 6_000,
    "max_tokens" => 1_500
  }

  # Defaults copied from GBrain's fact decay and purge constants.
  @forgetting_defaults %{
    "event_halflife_days" => 7,
    "preference_halflife_days" => 90,
    "commitment_halflife_days" => 90,
    "belief_halflife_days" => 365,
    "fact_halflife_days" => 365,
    "purge_soft_delete_ttl_hours" => 72
  }

  @doc """
  Returns the AppConfigure definitions owned by Brain.
  """
  @spec definitions() :: [Definition.t()]
  def definitions do
    [
      Definition.new!(
        key: @enabled_key,
        encrypted: false,
        scope: :global,
        schema: Schema.boolean(),
        default_value: true,
        description:
          "Whether BrainV3 is enabled. Disabling stops memory tools, context injection, and all Brain background tasks; stored data stays unchanged."
      ),
      Definition.new!(
        key: @embedding_model_key,
        encrypted: false,
        scope: :global,
        schema: model_schema(require_dimensions: true),
        default_value: nil,
        description:
          "Instance-global embedding model as {provider_id, model, dimensions, provider_options?}. Empty disables vector retrieval projections."
      ),
      Definition.new!(
        key: @rerank_model_key,
        encrypted: false,
        scope: :global,
        schema: model_schema(),
        default_value: nil,
        description:
          "Instance-global rerank model as {provider_id, model, provider_options?}. Empty skips rerank and keeps the fusion order."
      ),
      Definition.new!(
        key: @web_fetch_model_key,
        encrypted: false,
        scope: :global,
        schema: model_schema(),
        default_value: nil,
        description:
          "Instance-global web-fetch provider as {provider_id, model, provider_options?} for url Source learning. Empty stops url Source learning and reports unhealthy."
      ),
      Definition.new!(
        key: @extraction_model_key,
        encrypted: false,
        scope: :global,
        schema: model_schema(),
        default_value: nil,
        description:
          "Model for Signals processing and Source learning. Empty stops batch learning tasks and reports unhealthy."
      ),
      Definition.new!(
        key: @dreaming_model_key,
        encrypted: false,
        scope: :global,
        schema: model_schema(),
        default_value: nil,
        description:
          "Model for Dreaming consolidation, synthesis, and contradiction verdicts. Empty skips the model-dependent Dreaming phases and reports unhealthy."
      ),
      Definition.new!(
        key: @search_tokenizer_key,
        encrypted: false,
        scope: :global,
        schema: Schema.enum(@search_tokenizers),
        default_value: "icu",
        description:
          "pg_search BM25 tokenizer: icu, jieba, lindera_japanese, or lindera_korean. Changing it requires a BM25 index rebuild."
      ),
      Definition.new!(
        key: @chunking_key,
        encrypted: false,
        scope: :global,
        schema: chunking_schema(),
        default_value: @chunking_defaults,
        description:
          "Chunker settings: chunk_size, chunk_overlap (CJK-aware words), max_chars, and max_tokens (o200k_base). All values enter the chunking signature."
      ),
      Definition.new!(
        key: @forgetting_key,
        encrypted: false,
        scope: :global,
        schema: forgetting_schema(),
        default_value: @forgetting_defaults,
        description:
          "Fact decay halflives in days per kind, plus purge_soft_delete_ttl_hours for hard-deleting soft-deleted Objects."
      ),
      Definition.new!(
        key: @dreaming_task_cron_key,
        encrypted: false,
        scope: :global,
        schema: cron_schema(),
        default_value: "0 5 * * *",
        description: "Cron expression for the daily Dreaming maintenance task."
      ),
      Definition.new!(
        key: @self_healing_task_cron_key,
        encrypted: false,
        scope: :global,
        schema: cron_schema(),
        default_value: "*/15 * * * *",
        description:
          "Cron expression for the Self-healing task that rebuilds stale chunk, embedding, and index projections."
      ),
      Definition.new!(
        key: @signal_channel_batch_idle_time_key,
        encrypted: false,
        scope: :global,
        schema: positive_integer_schema(),
        default_value: 900,
        description:
          "Idle seconds after a signal channel's last message before its unprocessed slice enters batch learning. Conversation end also triggers it."
      ),
      Definition.new!(
        key: @skill_learning_enabled_key,
        encrypted: false,
        scope: :global,
        schema: Schema.boolean(),
        default_value: true,
        description:
          "Whether skill lessons are learned from job trajectories and delivered with skills. Disabling skips the Dreaming phase and hides stored lessons; data stays unchanged."
      ),
      Definition.new!(
        key: @skill_learning_reflection_threshold_key,
        encrypted: false,
        scope: :global,
        schema: bounded_integer_schema(2),
        default_value: 10,
        description:
          "Unconsumed signal jobs (mid-run human input or failed calls) an agent must accumulate before one skill-lesson reflection job starts. Minimum 2."
      )
    ]
  end

  @doc "Returns whether BrainV3 is enabled for this instance."
  @spec enabled?() :: boolean()
  def enabled?, do: get_or_default(@enabled_key, true)

  @doc "Returns the configured embedding model map or nil."
  @spec embedding_model() :: map() | nil
  def embedding_model, do: get_or_default(@embedding_model_key, nil)

  @doc "Returns the configured rerank model map or nil."
  @spec rerank_model() :: map() | nil
  def rerank_model, do: get_or_default(@rerank_model_key, nil)

  @doc "Returns the configured web-fetch provider map or nil."
  @spec web_fetch_model() :: map() | nil
  def web_fetch_model, do: get_or_default(@web_fetch_model_key, nil)

  @doc "Returns the configured extraction model map or nil."
  @spec extraction_model() :: map() | nil
  def extraction_model, do: get_or_default(@extraction_model_key, nil)

  @doc "Returns the configured dreaming model map or nil."
  @spec dreaming_model() :: map() | nil
  def dreaming_model, do: get_or_default(@dreaming_model_key, nil)

  @doc "Returns the deployment-level BM25 tokenizer name."
  @spec search_tokenizer() :: String.t()
  def search_tokenizer, do: get_or_default(@search_tokenizer_key, "icu")

  @doc "Returns the complete chunking settings map."
  @spec chunking() :: map()
  def chunking, do: get_or_default(@chunking_key, @chunking_defaults)

  @doc "Returns the complete forgetting settings map."
  @spec forgetting() :: map()
  def forgetting, do: get_or_default(@forgetting_key, @forgetting_defaults)

  @doc "Returns the Dreaming task cron expression."
  @spec dreaming_task_cron() :: String.t()
  def dreaming_task_cron, do: get_or_default(@dreaming_task_cron_key, "0 5 * * *")

  @doc "Returns the Self-healing task cron expression."
  @spec self_healing_task_cron() :: String.t()
  def self_healing_task_cron, do: get_or_default(@self_healing_task_cron_key, "*/15 * * * *")

  @doc "Returns the signal channel batch idle time in seconds."
  @spec signal_channel_batch_idle_time() :: pos_integer()
  def signal_channel_batch_idle_time, do: get_or_default(@signal_channel_batch_idle_time_key, 900)

  @doc "Returns whether skill-lesson learning is enabled."
  @spec skill_learning_enabled?() :: boolean()
  def skill_learning_enabled?, do: get_or_default(@skill_learning_enabled_key, true)

  @doc "Returns the signal-job count that triggers one skill-lesson reflection."
  @spec skill_learning_reflection_threshold() :: pos_integer()
  def skill_learning_reflection_threshold,
    do: get_or_default(@skill_learning_reflection_threshold_key, 10)

  @doc "Returns the allowed BM25 tokenizer names."
  @spec search_tokenizers() :: [String.t()]
  def search_tokenizers, do: @search_tokenizers

  @doc "Returns the hard upper bound for embedding dimensions."
  @spec max_embedding_dimensions() :: pos_integer()
  def max_embedding_dimensions, do: @max_embedding_dimensions

  @doc """
  Returns the read status of every `brain.*` key for the health surface:
  `:ok` (stored or default value), or `{:invalid, reason}` for a stored row
  that no longer validates. This read never raises, so the health page can
  report the broken key instead of failing with it.
  """
  @spec key_statuses() :: %{
          String.t() => :ok | {:invalid, String.t()} | {:unavailable, String.t()}
        }
  def key_statuses do
    definitions()
    |> Map.new(fn definition ->
      status =
        case AppConfigure.get_by_key(definition.key) do
          {:ok, _value} -> :ok
          :error -> :ok
          {:error, {:load_failed, _scope, _key, message}} -> {:unavailable, message}
          {:error, reason} -> {:invalid, inspect(reason)}
        end

      {definition.key, status}
    end)
  end

  # AppConfigure returns `{:ok, value}` for a stored or default value, bare
  # `:error` for a key with no value anywhere, and `{:error, reason}` for a
  # real failure. AppConfiguration.md forbids treating an invalid row as
  # absent, so an invalid row raises instead of silently running on defaults
  # that contradict the Console-saved value. A `:load_failed` read is a
  # different class — the store is unreachable, not the row invalid — and
  # serves the default with a warning so memory degrades instead of failing
  # every caller.
  defp get_or_default(key, default) do
    case AppConfigure.get_by_key(key) do
      {:ok, value} ->
        value

      :error ->
        default

      {:error, {:load_failed, _scope, _key, message}} ->
        Logging.warning(
          "brain.config.load_failed",
          "AppConfigure read failed; serving the code default",
          %{key: key, reason: message}
        )

        default

      {:error, reason} ->
        raise "invalid stored AppConfigure value for #{key}: #{inspect(reason)}"
    end
  end

  defp model_schema(opts \\ []) do
    require_dimensions? = Keyword.get(opts, :require_dimensions, false)

    allowed_keys =
      if require_dimensions?,
        do: ["provider_id", "model", "dimensions", "provider_options"],
        else: ["provider_id", "model", "provider_options"]

    Schema.new(fn
      nil ->
        {:ok, nil}

      value when is_map(value) ->
        with :ok <- only_keys(value, allowed_keys),
             :ok <- required_non_empty_string(value, "provider_id"),
             :ok <- required_non_empty_string(value, "model"),
             :ok <- optional_object(value, "provider_options"),
             :ok <- validate_dimensions(value, require_dimensions?) do
          {:ok, value}
        end

      _value ->
        {:error, :not_model_config}
    end)
  end

  defp validate_dimensions(value, false) do
    case Map.has_key?(value, "dimensions") do
      true -> {:error, {:unknown_key, "dimensions"}}
      false -> :ok
    end
  end

  defp validate_dimensions(value, true) do
    case Map.get(value, "dimensions") do
      dimensions when is_integer(dimensions) and dimensions > 0 ->
        if dimensions <= @max_embedding_dimensions,
          do: :ok,
          else: {:error, {:dimensions_above_limit, @max_embedding_dimensions}}

      _value ->
        {:error, {:invalid_field, "dimensions"}}
    end
  end

  defp chunking_schema do
    Schema.new(fn
      value when is_map(value) ->
        with :ok <- only_keys(value, Map.keys(@chunking_defaults)) do
          merged = Map.merge(@chunking_defaults, value)

          with :ok <- positive_int_field(merged, "chunk_size"),
               :ok <- non_negative_int_field(merged, "chunk_overlap"),
               :ok <- positive_int_field(merged, "max_chars"),
               :ok <- positive_int_field(merged, "max_tokens") do
            if merged["chunk_overlap"] < merged["chunk_size"],
              do: {:ok, merged},
              else: {:error, :chunk_overlap_not_below_chunk_size}
          end
        end

      _value ->
        {:error, :not_json_object}
    end)
  end

  defp forgetting_schema do
    Schema.new(fn
      value when is_map(value) ->
        with :ok <- only_keys(value, Map.keys(@forgetting_defaults)) do
          merged = Map.merge(@forgetting_defaults, value)

          Enum.reduce_while(Map.keys(@forgetting_defaults), {:ok, merged}, fn key, acc ->
            case positive_number_field(merged, key) do
              :ok -> {:cont, acc}
              {:error, _reason} = error -> {:halt, error}
            end
          end)
        end

      _value ->
        {:error, :not_json_object}
    end)
  end

  defp cron_schema do
    Schema.new(fn
      value when is_binary(value) ->
        case Crontab.CronExpression.Parser.parse(value) do
          {:ok, _expression} -> {:ok, value}
          {:error, _reason} -> {:error, :invalid_cron_expression}
        end

      _value ->
        {:error, :not_string}
    end)
  end

  defp positive_integer_schema do
    Schema.new(fn
      value when is_integer(value) and value > 0 -> {:ok, value}
      _value -> {:error, :not_positive_integer}
    end)
  end

  defp bounded_integer_schema(minimum) do
    Schema.new(fn
      value when is_integer(value) and value >= minimum -> {:ok, value}
      _value -> {:error, {:integer_below_minimum, minimum}}
    end)
  end

  defp only_keys(value, allowed_keys) do
    case Map.keys(value) -- allowed_keys do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_key, key}}
    end
  end

  defp required_non_empty_string(value, key) do
    case Map.get(value, key) do
      text when is_binary(text) and text != "" -> :ok
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp optional_object(value, key) do
    case Map.get(value, key) do
      nil ->
        :ok

      options when is_map(options) ->
        if Schema.json_value?(options), do: :ok, else: {:error, {:invalid_field, key}}

      _value ->
        {:error, {:invalid_field, key}}
    end
  end

  defp positive_int_field(value, key) do
    case Map.get(value, key) do
      int when is_integer(int) and int > 0 -> :ok
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp non_negative_int_field(value, key) do
    case Map.get(value, key) do
      int when is_integer(int) and int >= 0 -> :ok
      _value -> {:error, {:invalid_field, key}}
    end
  end

  defp positive_number_field(value, key) do
    case Map.get(value, key) do
      number when is_number(number) and number > 0 -> :ok
      _value -> {:error, {:invalid_field, key}}
    end
  end
end
