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
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Channel

  @doc """
  Returns the current Brain health snapshot.
  """
  @spec snapshot() :: map()
  def snapshot do
    %{
      enabled: safe(fn -> Config.enabled?() end, false),
      config: config_statuses(),
      models: %{
        embedding: model_status(safe(fn -> Config.embedding_model() end, nil)),
        rerank: model_status(safe(fn -> Config.rerank_model() end, nil)),
        web_fetch: model_status(safe(fn -> Config.web_fetch_model() end, nil)),
        extraction: model_status(safe(fn -> Config.extraction_model() end, nil)),
        dreaming: model_status(safe(fn -> Config.dreaming_model() end, nil))
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
      {key, :ok} -> {key, "ok"}
      {key, {:invalid, reason}} -> {key, %{invalid: reason}}
      {key, {:unavailable, reason}} -> {key, %{unavailable: reason}}
    end)
  end

  defp model_status(nil), do: %{configured: false}

  # A configured model whose provider row is missing or disabled fails
  # every call; `configured: true` alone would hide that.
  defp model_status(model) do
    provider =
      case ProviderConfigs.fetch_active_provider(model["provider_id"]) do
        {:ok, _provider} -> %{provider_available: true}
        {:error, reason} -> %{provider_available: false, provider_error: inspect(reason)}
      end

    Map.merge(
      %{configured: true, provider_id: model["provider_id"], model: model["model"]},
      provider
    )
  end

  defp embedding_signature do
    case Embeddings.signature() do
      {:ok, signature} -> signature
      {:error, reason} -> %{error: inspect(reason)}
    end
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
      recent_error: recent_error
    }
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
