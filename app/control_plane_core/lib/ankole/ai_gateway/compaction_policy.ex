defmodule Ankole.AIGateway.CompactionPolicy do
  @moduledoc "Compaction configuration, trigger thresholds and retention budgets."
  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Definition
  alias Ankole.AppConfigure.Schema
  alias Ankole.AIGateway.ModelMetadata
  alias Ankole.AIGateway.CompactionRender
  alias Ankole.AIGateway.CompactionSummarizer

  @config_key "ai_gateway.compaction"
  # Compact late. Every token below the trigger is replayed on each model call,
  # so a low trigger buys nothing and costs a summary, while each summary is a
  # memory loss the conversation pays for again by re-reading its own work.
  # This compaction runs on the request path, and the harnesses that compact on
  # their request path use nine tenths of the budget; the lower fractions
  # elsewhere belong to background passes that block nobody. The cap only
  # guards a window large enough to make one summary request absurd.
  @default_threshold_percent 0.90
  @default_max_threshold_tokens 400_000
  @default_context_length 256_000
  @minimum_context_length 64_000
  @small_context_trigger_ratio 0.85
  # A later trigger leaves room to hand the conversation back more of its own
  # recent work, which is what it otherwise reconstructs by re-reading files.
  # This is a row floor, not the budget fraction other harnesses retain, so it
  # moves one step rather than to their share.
  @default_tail_rows 4
  # Upstream compaction stays off by default for two reasons. A Provider-owned
  # compaction item binds the rest of that history to the same upstream, and the
  # item is ciphertext only its Provider can read, so every compacted stretch
  # leaves the stored trajectory. Long Jobs are improved by reading their own
  # history back — which calls repeated work, where the tokens went, what a
  # thread forgot — and that reading stops at the first opaque capsule.
  @default_upstream false
  @default_config %{
    "threshold" => @default_threshold_percent,
    "max_threshold_tokens" => @default_max_threshold_tokens,
    "tail_rows" => @default_tail_rows,
    "user_message_budget_tokens" => 20_000,
    "upstream" => @default_upstream
  }

  # Compaction summaries always use the `light` profile. The summarizer is
  # internal work with its own cost and latency profile, so it must not follow
  # whichever model the compacted conversation happened to use.

  @type threshold_spec :: %{
          tokens: pos_integer(),
          context_length: pos_integer(),
          effective_context_length: pos_integer(),
          threshold: float(),
          max_threshold_tokens: pos_integer(),
          max_output_tokens: pos_integer() | nil
        }

  @checkpoint_overhead_tokens 1_000
  @spec config_definition() :: Definition.t()
  def config_definition do
    AppConfigure.define(
      key: @config_key,
      encrypted: false,
      schema: config_schema(),
      default_value: @default_config,
      description:
        "AIGateway history compaction settings. `threshold` is a ratio of the model input context; `max_threshold_tokens` caps that computed trigger. `upstream` forwards the compaction request to the Provider instead of writing the summary locally; it is off by default because a Provider-owned compaction item binds the rest of that history to the same upstream."
    )
  end

  @doc """
  Returns whether this instance leaves compaction to the Provider.

  This is the only opt-in for Provider-native compaction. It is off by default
  because the local summarizer always works, and because a Provider-owned
  compaction item binds the rest of that history to the same upstream: no later
  local summary can read it.
  """
  @spec upstream_compaction?() :: boolean()
  def upstream_compaction? do
    Map.get(config(), "upstream", @default_upstream) == true
  end

  @spec threshold_spec(map(), map()) :: threshold_spec()
  def threshold_spec(runtime \\ %{}, request \\ %{}) do
    config = config()
    context_length = context_length(runtime)
    threshold_percent = Map.get(config, "threshold", @default_threshold_percent)
    max_threshold_tokens = Map.get(config, "max_threshold_tokens", @default_max_threshold_tokens)
    max_output_tokens = max_output_tokens(request)

    {computed_tokens, effective_context_length} =
      compute_threshold_tokens(context_length, threshold_percent, max_output_tokens)

    %{
      tokens: min(computed_tokens, max_threshold_tokens),
      context_length: context_length,
      effective_context_length: effective_context_length,
      threshold: threshold_percent,
      max_threshold_tokens: max_threshold_tokens,
      max_output_tokens: max_output_tokens
    }
  end

  def tail_rows do
    config()
    |> Map.get("tail_rows", @default_tail_rows)
  end

  def user_message_budget_tokens do
    config()
    |> Map.get("user_message_budget_tokens", 20_000)
  end

  @doc false
  @spec config() :: map()
  def config do
    {:ok, config} = AppConfigure.get(config_definition())
    config
  end

  defp config_schema do
    Schema.new(fn value ->
      with {:ok, value} <- normalize_config(value),
           :ok <- reject_unknown_config_keys(value),
           {:ok, threshold} <- optional_threshold(value),
           {:ok, max_threshold_tokens} <- optional_max_threshold_tokens(value),
           {:ok, tail_rows} <- optional_tail_rows(value),
           {:ok, user_message_budget_tokens} <- optional_user_message_budget_tokens(value),
           {:ok, upstream} <- optional_upstream(value) do
        {:ok,
         %{
           "threshold" => threshold,
           "max_threshold_tokens" => max_threshold_tokens,
           "tail_rows" => tail_rows,
           "user_message_budget_tokens" => user_message_budget_tokens,
           "upstream" => upstream
         }}
      end
    end)
  end

  defp normalize_config(value) when is_map(value),
    do: {:ok, Ankole.Attrs.normalize_external_attrs(value)}

  defp normalize_config(_value), do: {:error, :not_compaction_config}

  defp reject_unknown_config_keys(value) do
    allowed =
      MapSet.new([
        "threshold",
        "max_threshold_tokens",
        "tail_rows",
        "user_message_budget_tokens",
        "upstream"
      ])

    value
    |> Map.keys()
    |> Enum.reject(&MapSet.member?(allowed, &1))
    |> case do
      [] -> :ok
      keys -> {:error, {:unknown_compaction_config_keys, Enum.sort(keys)}}
    end
  end

  defp optional_threshold(value) do
    case Map.get(value, "threshold", @default_threshold_percent) do
      threshold when is_number(threshold) and threshold > 0 and threshold <= 1 ->
        {:ok, threshold * 1.0}

      _value ->
        {:error, :invalid_compaction_threshold}
    end
  end

  defp optional_tail_rows(value) do
    case Map.get(value, "tail_rows", @default_tail_rows) do
      tail_rows when is_integer(tail_rows) and tail_rows >= 0 -> {:ok, tail_rows}
      _value -> {:error, :invalid_compaction_tail_rows}
    end
  end

  defp optional_max_threshold_tokens(value) do
    case Map.get(value, "max_threshold_tokens", @default_max_threshold_tokens) do
      tokens when is_integer(tokens) and tokens > 0 -> {:ok, tokens}
      _value -> {:error, :invalid_compaction_max_threshold_tokens}
    end
  end

  defp optional_user_message_budget_tokens(value) do
    case Map.get(value, "user_message_budget_tokens", 20_000) do
      tokens when is_integer(tokens) and tokens > 0 -> {:ok, tokens}
      _value -> {:error, :invalid_compaction_user_message_budget_tokens}
    end
  end

  defp optional_upstream(value) do
    case Map.get(value, "upstream", @default_upstream) do
      upstream when is_boolean(upstream) -> {:ok, upstream}
      _value -> {:error, :invalid_compaction_upstream}
    end
  end

  defp context_length(runtime),
    do: ModelMetadata.runtime_context_length(runtime) || @default_context_length

  defp max_output_tokens(request) when is_map(request) do
    first_positive_integer([
      Map.get(request, "max_output_tokens"),
      Map.get(request, "max_tokens")
    ])
  end

  defp max_output_tokens(_request), do: nil

  defp compute_threshold_tokens(context_length, threshold_percent, max_output_tokens) do
    context_length = positive_integer_or(context_length, @default_context_length)
    threshold_percent = positive_number_or(threshold_percent, @default_threshold_percent)
    output_reservation = positive_integer_or(max_output_tokens, 0)

    effective_context_length =
      case context_length - output_reservation do
        value when value > 0 -> value
        _value -> context_length
      end

    percentage_value = floor(effective_context_length * threshold_percent)
    floored = max(percentage_value, @minimum_context_length)

    tokens =
      if effective_context_length > 0 and floored >= effective_context_length do
        max(
          1,
          min(
            floor(effective_context_length * @small_context_trigger_ratio),
            effective_context_length - 1
          )
        )
      else
        floored
      end

    {tokens, effective_context_length}
  end

  defp first_positive_integer(values) do
    Enum.find_value(values, fn value ->
      case positive_integer(value) do
        nil -> false
        integer -> integer
      end
    end)
  end

  defp positive_integer_or(value, fallback) do
    positive_integer(value) || fallback
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Ankole.Attrs.integer_value(value) do
      integer when is_integer(integer) and integer > 0 -> integer
      _value -> nil
    end
  end

  defp positive_integer(_value), do: nil

  defp positive_number_or(value, _fallback) when is_number(value) and value > 0, do: value
  defp positive_number_or(_value, fallback), do: fallback

  def checkpoint_budget_tokens(threshold) do
    max(threshold.tokens, CompactionRender.min_render_budget_tokens())
  end

  def retained_tail_budget_tokens(threshold, pack) do
    preferred_budget =
      max(
        checkpoint_budget_tokens(threshold) -
          user_message_budget_tokens() -
          CompactionSummarizer.max_output_tokens() -
          @checkpoint_overhead_tokens,
        CompactionRender.min_render_budget_tokens()
      )

    max(preferred_budget - Ankole.AIGateway.CompactionHistory.items_token_estimate(pack), 0)
  end
end
