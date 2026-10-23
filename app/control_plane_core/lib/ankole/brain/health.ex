defmodule Ankole.Brain.Health do
  @moduledoc """
  Internal health surface for the Console health page and operations.

  The snapshot must render while the thing it reports is broken: config
  reads that would raise on an invalid stored row degrade to their absent
  shape here, and the `config` section names the invalid key.
  """

  require Ash.Query

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Brain.Calibration
  alias Ankole.Brain.Config
  alias Ankole.Brain.ContextPackStats
  alias Ankole.Brain.Embeddings
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.ConversationsLearning
  alias Ankole.Logging

  @internal_error "internal_error"
  @public_reasons ~w(
    not_found provider_disabled invalid_embedding_model_ref
    brain_maintainer_agent_not_configured brain_maintainer_agent_disabled agent_not_found
    invalid_model_profile
  )

  @doc """
  Returns the current Brain health snapshot.
  """
  @spec snapshot() :: map()
  def snapshot do
    %{
      enabled: safe(fn -> Config.enabled?() end, false),
      maintainer_agent_uid: safe(fn -> Config.maintainer_agent_uid() end, nil),
      config: config_statuses(),
      models: %{
        embedding: model_status(safe(fn -> Config.embedding_model() end, nil)),
        rerank: model_status(safe(fn -> Config.rerank_model() end, nil)),
        web_fetch: profile_model_status("web_fetch"),
        extraction: profile_model_status("light"),
        dreaming: profile_model_status("heavy")
      },
      embedding_signature: embedding_signature(),
      grading: safe(&Calibration.grading_status/0, %{status: "skipped", reason: @internal_error}),
      signals: signals_status(),
      embeddings: embedding_status(),
      context_pack: ContextPackStats.snapshot(),
      channels_without_member_group: group_channels_without_member_group(),
      skill_lessons: safe(&skill_lesson_status/0, %{})
    }
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    _invalid_config -> fallback
  end

  # All three drift signals come from the one lessons table: active counts
  # per agent, recent additions and retirements, and the age of the oldest
  # still-active leased lesson.
  defp skill_lesson_status do
    week_floor = DateTime.add(DateTime.utc_now(), -7, :day)

    # The lessons of one tenant are few, so the counts group in memory.
    lessons =
      Ankole.AIAgent.list_agent_skill_lessons!(
        query: [
          filter: [or: [[retired_at: [is_nil: true]], [retired_at: [greater_than: week_floor]]]],
          select: [:agent_uid, :inserted_at, :retired_at, :retire_reason, :author_kind]
        ]
      )

    active = Enum.filter(lessons, &is_nil(&1.retired_at))

    added_last_7d =
      Ankole.AIAgent.list_agent_skill_lessons!(
        query: [filter: [inserted_at: [greater_than: week_floor]], select: [:id]]
      )
      |> length()

    oldest_active =
      active
      |> Enum.filter(&(&1.author_kind == :dreaming))
      |> Enum.map(& &1.inserted_at)
      |> Enum.min(DateTime, fn -> nil end)

    %{
      enabled: Config.skill_learning_enabled?(),
      active_per_agent: Enum.frequencies_by(active, & &1.agent_uid),
      added_last_7d: added_last_7d,
      retired_last_7d:
        lessons
        |> Enum.reject(&is_nil(&1.retired_at))
        |> Enum.frequencies_by(&to_string(&1.retire_reason)),
      oldest_active_days:
        oldest_active && div(DateTime.diff(DateTime.utc_now(), oldest_active, :second), 86_400)
    }
  end

  defp config_statuses do
    Config.key_statuses()
    |> Map.new(fn
      {key, :ok} ->
        {key, "ok"}

      {key, {:invalid, reason}} ->
        log_config_error(key, "invalid", reason)
        {key, %{invalid: "invalid_value"}}

      {key, {:unavailable, reason}} ->
        log_config_error(key, "unavailable", reason)
        {key, %{unavailable: "store_unavailable"}}
    end)
  end

  defp model_status(nil), do: %{configured: false}

  # A configured model whose provider row is missing or disabled fails
  # every call; `configured: true` alone would hide that.
  defp model_status(model) do
    provider =
      case ProviderConfigs.fetch_active_provider(model["provider_id"]) do
        {:ok, _provider} ->
          %{provider_available: true}

        {:error, reason} ->
          %{
            provider_available: false,
            provider_error: public_reason(reason, "model_provider")
          }
      end

    Map.merge(
      %{configured: true, provider_id: model["provider_id"], model: model["model"]},
      provider
    )
  end

  defp profile_model_status(profile) do
    case safe(fn -> Config.maintainer_model_profile(profile) end, {:error, :internal_error}) do
      {:ok, model} ->
        model
        |> model_status()
        |> Map.put(:profile, profile)

      {:error, :model_profile_not_configured} ->
        %{configured: false, profile: profile}

      {:error, reason} ->
        %{
          configured: false,
          profile: profile,
          profile_error: public_reason(reason, "maintainer_profile")
        }
    end
  end

  defp embedding_signature do
    case Embeddings.signature() do
      {:ok, signature} -> signature
      # No configured embedding model means no signature, not an error blob.
      {:error, :embedding_model_not_configured} -> nil
      {:error, reason} -> %{error: public_reason(reason, "embedding_signature")}
    end
  end

  defp public_reason(reason, area) do
    reason_text = if is_atom(reason), do: Atom.to_string(reason), else: reason

    if is_binary(reason_text) and reason_text in @public_reasons do
      reason_text
    else
      Logging.error(
        "brain.health.internal_error",
        "Brain health hid an internal error",
        %{area: area, reason: inspect(reason)}
      )

      @internal_error
    end
  end

  defp log_config_error(key, status, reason) do
    Logging.warning(
      "brain.health.config_unhealthy",
      "Brain health found an unhealthy stored setting",
      %{key: key, status: status, reason: reason}
    )
  end

  # Queue depth: idle channels whose slices are pending, plus the oldest
  # pending entry age in seconds.
  defp signals_status do
    slices = ConversationsLearning.idle_pending_slices()
    oldest = slices |> Enum.map(& &1.first_seen_at) |> Enum.min(DateTime, fn -> nil end)
    age = oldest && DateTime.diff(DateTime.utc_now(), oldest)
    %{pending_channels: length(slices), oldest_pending_age_seconds: age}
  end

  defp embedding_status do
    chunk_failures = Chunk |> Ash.Query.filter(embedding_failed? == true) |> count()
    claim_failures = Claim |> Ash.Query.filter(embedding_failed? == true) |> count()
    pending_chunks = Chunk |> Ash.Query.filter(is_nil(embedded_at)) |> count()

    recent_error =
      Chunk
      |> Ash.Query.filter(embedding_failed? == true)
      |> Ash.Query.sort(created_at: :desc)
      |> Ash.Query.select([:embedding_error])
      |> Ash.Query.limit(1)
      |> Ankole.Ash.read_one!()
      |> then(&(&1 && &1.embedding_error))

    %{
      failed_chunks: chunk_failures,
      failed_claims: claim_failures,
      pending_chunks: pending_chunks,
      recent_error: recent_embedding_error(recent_error)
    }
  end

  defp count(query), do: Ankole.Ash.aggregate!(query, {:count, :count}).count

  defp recent_embedding_error(nil), do: nil

  defp recent_embedding_error(reason) do
    Logging.error(
      "brain.health.internal_error",
      "Brain health hid an internal embedding error",
      %{area: "embedding_projection", reason: reason}
    )

    @internal_error
  end

  # Group channels without a member group cannot learn; the deterministic
  # default scope has no target.
  defp group_channels_without_member_group do
    [
      query: [
        filter: [kind: :external, external_kind: :im_group, principal_group_id: [is_nil: true]],
        select: [:id]
      ]
    ]
    |> Ankole.Conversations.list_conversations!()
    |> Enum.map(& &1.id)
  end
end
