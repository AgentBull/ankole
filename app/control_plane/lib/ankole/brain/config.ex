defmodule Ankole.Brain.Config do
  @moduledoc """
  AppConfigure declarations and typed reads for the `brain.*` key group.

  The embedding model is site-wide because all Brain rows share one vector
  space. Brain calls execute as the tenant's `ankole_brain` Principal, whose
  model profiles inherit the Pod and Site defaults owned by AIGateway.
  """

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.Logging
  alias Ankole.Principals

  @execution_subject_uid "ankole_brain"
  @enabled_key "brain.enabled"
  @embedding_model_key "brain.embedding_model"
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
    "fact_halflife_days" => 365
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
        scope: :tenant,
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
          "Site-wide embedding model as {provider_id, model, dimensions, provider_options?}. Empty disables vector retrieval projections."
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
        scope: :tenant,
        schema: chunking_schema(),
        default_value: @chunking_defaults,
        description:
          "Chunker settings: chunk_size, chunk_overlap (CJK-aware words), max_chars, and max_tokens (o200k_base). All values enter the chunking signature."
      ),
      Definition.new!(
        key: @forgetting_key,
        encrypted: false,
        scope: :tenant,
        schema: forgetting_schema(),
        default_value: @forgetting_defaults,
        description: "Fact decay halflives in days per kind."
      ),
      Definition.new!(
        key: "brain.soft_delete_retention_hours",
        encrypted: false,
        scope: :tenant,
        schema:
          Schema.new(fn value ->
            if is_number(value) and value > 0,
              do: {:ok, value},
              else: {:error, :invalid_retention_hours}
          end),
        default_value: 72,
        description:
          "Hours before Dreaming permanently deletes eligible soft-deleted Brain Objects."
      ),
      Definition.new!(
        key: @dreaming_task_cron_key,
        encrypted: false,
        scope: :tenant,
        schema: cron_schema(),
        default_value: "0 5 * * *",
        description: "Cron expression for the daily Dreaming maintenance task."
      ),
      Definition.new!(
        key: @self_healing_task_cron_key,
        encrypted: false,
        scope: :tenant,
        schema: cron_schema(),
        default_value: "*/15 * * * *",
        description:
          "Cron expression for the Self-healing task that rebuilds stale chunk, embedding, and index projections."
      ),
      Definition.new!(
        key: @signal_channel_batch_idle_time_key,
        encrypted: false,
        scope: :tenant,
        schema: positive_integer_schema(),
        default_value: 900,
        description:
          "Idle seconds after a signal channel's last message before its unprocessed slice enters batch learning. Conversation end also triggers it."
      ),
      Definition.new!(
        key: @skill_learning_enabled_key,
        encrypted: false,
        scope: :tenant,
        schema: Schema.boolean(),
        default_value: true,
        description:
          "Whether skill lessons are learned from job trajectories and delivered with skills. Disabling skips the Dreaming phase and hides stored lessons; data stays unchanged."
      ),
      Definition.new!(
        key: @skill_learning_reflection_threshold_key,
        encrypted: false,
        scope: :tenant,
        schema: bounded_integer_schema(2),
        default_value: 10,
        description:
          "Unconsumed signal jobs (mid-run human input or failed calls) an agent must accumulate before one skill-lesson reflection job starts. Minimum 2."
      )
    ]
  end

  @doc "Returns whether BrainV3 is enabled for this instance."
  @spec enabled?() :: boolean()
  def enabled?, do: get_or_default(@enabled_key)

  @doc "Returns the tenant's ankole_brain Principal UID used by Brain model calls."
  @spec execution_subject_uid() :: {:ok, String.t()} | {:error, term()}
  def execution_subject_uid do
    with {:ok, principal} <- Principals.system_principal(@execution_subject_uid),
         do: {:ok, principal.uid}
  end

  @doc "Returns the audit author for Brain maintenance writes; a missing service Principal is an error."
  @spec execution_author!() :: Ankole.ActorRef.t()
  def execution_author! do
    case Principals.system_principal(@execution_subject_uid) do
      {:ok, principal} -> Ankole.ActorRef.from_principal(principal)
      {:error, reason} -> raise "Brain system Principal unavailable: #{inspect(reason)}"
    end
  end

  @doc "Returns the configured embedding model map or nil."
  @spec embedding_model() :: map() | nil
  def embedding_model, do: get_or_default(@embedding_model_key)

  @doc "Returns ankole_brain's effective rerank model map or nil."
  @spec rerank_model() :: map() | nil
  def rerank_model, do: profile_or_nil("rerank")

  @doc "Lists stored site embedding settings that reference a Provider."
  @spec model_provider_references(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def model_provider_references(provider_id) do
    query = [query: [filter: [key: [eq: @embedding_model_key]]]]

    with {:ok, rows} <- AppConfigure.list_site_configs(query) do
      provider_references(rows, provider_id)
    end
  end

  defp provider_references(rows, provider_id) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, refs} ->
      with {:ok, definition} <- Ankole.AppConfigure.Registry.require_key(row.key),
           {:ok, value} <-
             Ankole.AppConfigure.Codec.load(definition, row.scope, row.key, row.value) do
        if match?(%{"provider_id" => ^provider_id}, value),
          do: {:cont, {:ok, [row.key | refs]}},
          else: {:cont, {:ok, refs}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, refs} -> {:ok, Enum.reverse(refs)}
      error -> error
    end
  end

  @doc "Returns ankole_brain's effective web-fetch model or nil."
  @spec web_fetch_model() :: map() | nil
  def web_fetch_model, do: profile_or_nil("web_fetch")

  @doc "Returns ankole_brain's effective light model for extraction or nil."
  @spec extraction_model() :: map() | nil
  def extraction_model, do: profile_or_nil("light")

  @doc "Returns ankole_brain's effective heavy model for Dreaming or nil."
  @spec dreaming_model() :: map() | nil
  def dreaming_model, do: profile_or_nil("heavy")

  @doc "Reads one effective ankole_brain model profile, with heavy falling back to primary."
  @spec effective_model_profile(String.t()) :: {:ok, map()} | {:error, term()}
  def effective_model_profile(profile) when is_binary(profile) do
    with {:ok, configuration} <-
           ModelProfiles.system_model_profile_configuration(@execution_subject_uid),
         %{value: %{} = model} <- Map.get(configuration.effective, profile) do
      {:ok, model}
    else
      %{value: nil} when profile == "heavy" -> effective_model_profile("primary")
      %{value: nil} -> {:error, :model_profile_not_configured}
      nil -> {:error, :invalid_model_profile}
      {:error, _reason} = error -> error
    end
  end

  @doc "Returns the deployment-level BM25 tokenizer name."
  @spec search_tokenizer() :: String.t()
  def search_tokenizer, do: get_or_default(@search_tokenizer_key)

  @doc "Returns the complete chunking settings map."
  @spec chunking() :: map()
  def chunking, do: get_or_default(@chunking_key)

  @doc "Returns the complete forgetting settings map."
  @spec forgetting() :: map()
  def forgetting, do: get_or_default(@forgetting_key)

  def soft_delete_retention_hours, do: get_or_default("brain.soft_delete_retention_hours")

  @doc "Returns the Dreaming task cron expression."
  @spec dreaming_task_cron() :: String.t()
  def dreaming_task_cron, do: get_or_default(@dreaming_task_cron_key)

  @doc "Returns the Self-healing task cron expression."
  @spec self_healing_task_cron() :: String.t()
  def self_healing_task_cron, do: get_or_default(@self_healing_task_cron_key)

  @doc "Returns the signal channel batch idle time in seconds."
  @spec signal_channel_batch_idle_time() :: pos_integer()
  def signal_channel_batch_idle_time, do: get_or_default(@signal_channel_batch_idle_time_key)

  @doc "Returns whether skill-lesson learning is enabled."
  @spec skill_learning_enabled?() :: boolean()
  def skill_learning_enabled?, do: get_or_default(@skill_learning_enabled_key)

  @doc "Returns the signal-job count that triggers one skill-lesson reflection."
  @spec skill_learning_reflection_threshold() :: pos_integer()
  def skill_learning_reflection_threshold,
    do: get_or_default(@skill_learning_reflection_threshold_key)

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

  # AppConfigure returns `{:ok, value}` for a stored or default value and
  # `{:error, reason}` for a
  # real failure. AppConfiguration.md forbids treating an invalid row as
  # absent, so an invalid row raises instead of silently running on defaults
  # that contradict the Console-saved value. A `:load_failed` read is a
  # different class — the store is unreachable, not the row invalid — and
  # serves the definition default with a warning so memory degrades instead of failing
  # every caller.
  defp get_or_default(key) do
    case AppConfigure.get_by_key(key) do
      {:ok, value} ->
        value

      {:error, {:load_failed, _scope, _key, message}} ->
        Logging.warning(
          "brain.config.load_failed",
          "AppConfigure read failed; serving the code default",
          %{key: key, reason: message}
        )

        definition_default(key)

      {:error, reason} ->
        raise "invalid stored AppConfigure value for #{key}: #{inspect(reason)}"
    end
  end

  defp definition_default(key) do
    %Definition{default_value: value} = Enum.find(definitions(), &(&1.key == key))
    value
  end

  defp profile_or_nil(profile) do
    case effective_model_profile(profile) do
      {:ok, model} ->
        model

      {:error, :system_principal_missing} ->
        raise "Brain system Principal unavailable: :system_principal_missing"

      {:error, _reason} ->
        nil
    end
  end

  defp model_schema(opts) do
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
      true -> {:error, {:invalid_field, "dimensions"}}
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
      [key | _rest] -> {:error, {:invalid_field, key}}
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
