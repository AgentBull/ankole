defmodule Ankole.Brain.Health do
  @moduledoc """
  Internal health surface for the Console health page and operations.

  The snapshot must render while the thing it reports is broken: config
  reads that would raise on an invalid stored row degrade to their absent
  shape here, and the `config` section names the invalid key.
  """

  import Ecto.Query, warn: false

  alias Ankole.AIAgent.Library.Schemas.AgentSkillLesson
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.Brain.Config
  alias Ankole.Brain.ContextPackStats
  alias Ankole.Brain.Embeddings
  alias Ankole.Brain.Schemas.Chunk
  alias Ankole.Brain.Schemas.Claim
  alias Ankole.Brain.SignalsLearning
  alias Ankole.Logging
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel

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
        web_fetch: profile_model_status("web_fetch", fallback: "ankole_browser"),
        extraction: profile_model_status("light"),
        dreaming: profile_model_status("heavy")
      },
      embedding_signature: embedding_signature(),
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

    active_per_agent =
      AgentSkillLesson
      |> where([lesson], is_nil(lesson.retired_at))
      |> group_by([lesson], lesson.agent_uid)
      |> select([lesson], {lesson.agent_uid, count(lesson.id)})
      |> Repo.all()
      |> Map.new()

    added_last_7d =
      AgentSkillLesson
      |> where([lesson], lesson.inserted_at > ^week_floor)
      |> Repo.aggregate(:count)

    retired_last_7d =
      AgentSkillLesson
      |> where([lesson], lesson.retired_at > ^week_floor)
      |> group_by([lesson], lesson.retire_reason)
      |> select([lesson], {lesson.retire_reason, count(lesson.id)})
      |> Repo.all()
      |> Map.new()

    oldest_active =
      AgentSkillLesson
      |> where([lesson], is_nil(lesson.retired_at))
      |> where([lesson], lesson.author_kind == "dreaming")
      |> select([lesson], min(lesson.inserted_at))
      |> Repo.one()

    %{
      enabled: Config.skill_learning_enabled?(),
      active_per_agent: active_per_agent,
      added_last_7d: added_last_7d,
      retired_last_7d: retired_last_7d,
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

  defp profile_model_status(profile, opts \\ []) do
    case safe(fn -> Config.maintainer_model_profile(profile) end, {:error, :internal_error}) do
      {:ok, model} ->
        model
        |> model_status()
        |> Map.put(:profile, profile)
        |> maybe_put_fallback(Keyword.get(opts, :fallback))

      {:error, :model_profile_not_configured} ->
        %{configured: false, profile: profile}
        |> maybe_put_fallback(Keyword.get(opts, :fallback))

      {:error, reason} ->
        %{
          configured: false,
          profile: profile,
          profile_error: public_reason(reason, "maintainer_profile")
        }
    end
  end

  defp maybe_put_fallback(status, fallback) when is_binary(fallback),
    do: Map.put(status, :fallback, fallback)

  defp maybe_put_fallback(status, _fallback), do: status

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
    channel_ids = SignalsLearning.idle_channels_with_pending_slices()

    oldest_age_seconds =
      case channel_ids do
        [] ->
          nil

        ids ->
          ids
          |> Enum.flat_map(fn channel_id ->
            case SignalsLearning.pending_slice(channel_id, 1) do
              [] -> []
              [first] -> [first.first_seen_at]
            end
          end)
          |> case do
            [] -> nil
            timestamps -> DateTime.diff(DateTime.utc_now(), Enum.min(timestamps, DateTime))
          end
      end

    %{pending_channels: length(channel_ids), oldest_pending_age_seconds: oldest_age_seconds}
  end

  defp embedding_status do
    chunk_failures =
      Chunk |> where([chunk], not is_nil(chunk.embedding_error)) |> Repo.aggregate(:count)

    claim_failures =
      Claim |> where([claim], not is_nil(claim.embedding_error)) |> Repo.aggregate(:count)

    pending_chunks =
      Chunk |> where([chunk], is_nil(chunk.embedded_at)) |> Repo.aggregate(:count)

    recent_error =
      Chunk
      |> where([chunk], not is_nil(chunk.embedding_error))
      |> order_by([chunk], desc: chunk.created_at)
      |> limit(1)
      |> select([chunk], chunk.embedding_error)
      |> Repo.one()

    %{
      failed_chunks: chunk_failures,
      failed_claims: claim_failures,
      pending_chunks: pending_chunks,
      recent_error: recent_embedding_error(recent_error)
    }
  end

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
    Channel
    |> where([channel], channel.kind == :im_group)
    |> where([channel], is_nil(channel.principal_group_id))
    |> select([channel], channel.id)
    |> Repo.all()
  end
end
