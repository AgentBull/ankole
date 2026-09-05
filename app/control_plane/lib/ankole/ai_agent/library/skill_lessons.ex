defmodule Ankole.AIAgent.Library.SkillLessons do
  @moduledoc false

  import Ecto.Query
  alias Ankole.AIAgent.Library.Schemas.{AgentSkill, AgentSkillLesson}
  alias Ankole.AIAgent.Library.SourceReader
  alias Ankole.Brain.Config, as: BrainConfig
  alias Ankole.Brain.Sanitize
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Principals
  alias Ankole.Principals.Agent
  alias Ankole.Repo

  def apply_adds_in_tx(repo, agent_uid, adds, context, now, catalog) do
    state = %{
      repo: repo,
      catalog: catalog,
      now: now,
      context: context,
      active: active_lesson_index(repo, agent_uid),
      immunity: immunity_index(repo, agent_uid),
      accepted: [],
      rejected: [],
      round_counts: %{}
    }

    state = Enum.reduce(adds, state, &apply_lesson_add(agent_uid, &1, &2))
    {:ok, %{accepted: Enum.reverse(state.accepted), rejected: Enum.reverse(state.rejected)}}
  end

  def create_in_tx(repo, agent_uid, skill_name, content, author_uid) do
    with :ok <- validate_lesson_content(content, :human) do
      %AgentSkillLesson{}
      |> AgentSkillLesson.changeset(%{
        agent_uid: agent_uid,
        skill_name: skill_name,
        content: String.trim(content),
        author_kind: "human",
        author_uid: author_uid
      })
      |> repo.insert()
    end
  end

  def rendered(repo, agent_uid, skill_names) do
    lessons =
      if BrainConfig.skill_learning_enabled?(),
        do:
          repo
          |> delivered_skill_lessons(agent_uid, skill_names)
          |> Enum.group_by(& &1.skill_name),
        else: %{}

    Map.new(skill_names, &{&1, rendered_lesson_entry(Map.get(lessons, &1, []))})
  end

  defp ensure_agent(repo, agent_uid) do
    case repo.get(Agent, agent_uid) do
      %Agent{} -> :ok
      nil -> {:error, :not_found}
    end
  end

  def apply_skill_lesson_reviews(agent_uid, reviews, docket_ids, context, opts \\ [])
      when is_list(reviews) do
    repo = Keyword.get(opts, :repo, Repo)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      repo.transact(fn repo ->
        state = %{
          repo: repo,
          now: now,
          context: context,
          docket_ids: docket_ids,
          renewed: 0,
          retired_skills: [],
          lapsed: 0,
          obsoleted: 0,
          rejected: []
        }

        state = Enum.reduce(reviews, state, &apply_lesson_review(agent_uid, &1, &2))

        {:ok,
         %{
           renewed: state.renewed,
           obsoleted: state.obsoleted,
           lapsed: state.lapsed,
           rejected: Enum.reverse(state.rejected),
           retired_skills: Enum.uniq(state.retired_skills)
         }}
      end)
    end
  end

  def skill_lesson_review_docket(agent_uid, horizon, current_release, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      skill_hashes =
        AgentSkill
        |> where([skill], skill.agent_uid == ^agent_uid)
        |> select([skill], {skill.skill_name, skill.content_hash})
        |> repo.all()
        |> Map.new()

      docket =
        AgentSkillLesson
        |> where([lesson], lesson.agent_uid == ^agent_uid)
        |> where([lesson], is_nil(lesson.retired_at))
        |> where([lesson], lesson.author_kind == "dreaming")
        |> order_by([lesson], asc: lesson.inserted_at)
        |> repo.all()
        |> Enum.filter(fn lesson ->
          DateTime.compare(lesson.review_after, horizon) != :gt or
            lesson.checked_release != current_release or
            lesson.checked_skill_hash != Map.get(skill_hashes, lesson.skill_name)
        end)

      {:ok, docket}
    end
  end

  def retire_skill_lesson(agent_uid, lesson_id, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         :ok <- ensure_agent(repo, agent_uid) do
      repo.transact(fn repo ->
        case repo.get_by(AgentSkillLesson, id: lesson_id, agent_uid: agent_uid) do
          nil ->
            {:error, :skill_lesson_not_found}

          %AgentSkillLesson{retired_at: %DateTime{}} ->
            {:error, :skill_lesson_already_retired}

          %AgentSkillLesson{} = lesson ->
            lesson
            |> AgentSkillLesson.changeset(%{
              retired_at: DateTime.utc_now(:microsecond),
              retire_reason: "human_revoked"
            })
            |> repo.update()
        end
      end)
    end
  end

  def active_skill_lessons(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      {:ok,
       AgentSkillLesson
       |> where([lesson], lesson.agent_uid == ^agent_uid)
       |> where([lesson], is_nil(lesson.retired_at))
       |> order_by([lesson], asc: lesson.skill_name, asc: lesson.inserted_at)
       |> repo.all()}
    end
  end

  def revoked_skill_lessons(agent_uid, opts \\ []) do
    repo = Keyword.get(opts, :repo, Repo)

    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      {:ok,
       AgentSkillLesson
       |> where([lesson], lesson.agent_uid == ^agent_uid)
       |> where([lesson], lesson.retire_reason == "human_revoked")
       |> order_by([lesson], asc: lesson.skill_name, asc: lesson.inserted_at)
       |> repo.all()}
    end
  end

  @lesson_term_days 7
  @lesson_delivery_grace_days 7
  @lesson_adds_per_skill 2
  @lesson_active_cap 10
  @lesson_token_limit 100
  @lesson_url_pattern ~r/https?:\/\//i
  @lesson_render_header "Field notes (dated; verify against the current environment):"

  defp delivered_skill_lessons(repo, agent_uid, skill_names) do
    grace_floor =
      DateTime.add(DateTime.utc_now(:microsecond), -@lesson_delivery_grace_days, :day)

    AgentSkillLesson
    |> where([lesson], lesson.agent_uid == ^agent_uid)
    |> where([lesson], lesson.skill_name in ^skill_names)
    |> where([lesson], is_nil(lesson.retired_at))
    |> where([lesson], is_nil(lesson.review_after) or lesson.review_after > ^grace_floor)
    |> order_by([lesson], asc: lesson.inserted_at)
    |> repo.all()
  end

  def delivered_skill_names(repo, agent_uid) do
    if BrainConfig.skill_learning_enabled?() do
      grace_floor =
        DateTime.add(DateTime.utc_now(:microsecond), -@lesson_delivery_grace_days, :day)

      AgentSkillLesson
      |> where([lesson], lesson.agent_uid == ^agent_uid)
      |> where([lesson], is_nil(lesson.retired_at))
      |> where([lesson], is_nil(lesson.review_after) or lesson.review_after > ^grace_floor)
      |> select([lesson], lesson.skill_name)
      |> repo.all()
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  def delivered_text(repo, agent_uid, skill_name) do
    if BrainConfig.skill_learning_enabled?() do
      repo
      |> delivered_skill_lessons(agent_uid, [skill_name])
      |> render_skill_lessons()
    else
      nil
    end
  end

  defp rendered_lesson_entry(lessons) do
    case render_skill_lessons(lessons) do
      nil ->
        %{"text" => "", "content_hash" => "", "has_lessons" => false}

      text ->
        %{"text" => text, "content_hash" => SourceReader.hash(text), "has_lessons" => true}
    end
  end

  defp render_skill_lessons([]), do: nil

  defp render_skill_lessons(lessons) do
    {human, dreaming} = Enum.split_with(lessons, &(&1.author_kind == "human"))
    bullets = Enum.map(human ++ dreaming, &lesson_bullet/1)
    Enum.join([@lesson_render_header | bullets], "\n")
  end

  defp lesson_bullet(%AgentSkillLesson{} = lesson) do
    date = lesson.inserted_at |> DateTime.to_date() |> Date.to_iso8601()
    marker = if lesson.author_kind == "human", do: date <> ", human", else: date
    "- [" <> marker <> "] " <> String.trim(lesson.content)
  end

  defp active_lesson_index(repo, agent_uid) do
    AgentSkillLesson
    |> where([lesson], lesson.agent_uid == ^agent_uid)
    |> where([lesson], is_nil(lesson.retired_at))
    |> repo.all()
    |> Enum.reduce(%{}, &index_lesson(&2, &1))
  end

  defp index_lesson(index, %AgentSkillLesson{} = lesson) do
    entry = Map.get(index, lesson.skill_name, %{count: 0, normalized: MapSet.new()})

    Map.put(index, lesson.skill_name, %{
      count: entry.count + 1,
      normalized: MapSet.put(entry.normalized, normalize_lesson_text(lesson.content))
    })
  end

  defp immunity_index(repo, agent_uid) do
    AgentSkillLesson
    |> where([lesson], lesson.agent_uid == ^agent_uid)
    |> where([lesson], lesson.retire_reason == "human_revoked")
    |> repo.all()
    |> Enum.group_by(& &1.skill_name, &normalize_lesson_text(&1.content))
    |> Map.new(fn {skill_name, normals} -> {skill_name, MapSet.new(normals)} end)
  end

  defp normalize_lesson_text(text) do
    text
    |> String.normalize(:nfkc)
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp apply_lesson_add(agent_uid, add, state) do
    case validate_lesson_add(agent_uid, add, state) do
      {:ok, attrs} ->
        case %AgentSkillLesson{} |> AgentSkillLesson.changeset(attrs) |> state.repo.insert() do
          {:ok, lesson} ->
            %{
              state
              | accepted: [lesson | state.accepted],
                active: index_lesson(state.active, lesson),
                round_counts: Map.update(state.round_counts, lesson.skill_name, 1, &(&1 + 1))
            }

          {:error, _changeset} ->
            reject_add(state, add, :invalid_add)
        end

      {:error, reason} ->
        reject_add(state, add, reason)
    end
  end

  defp validate_lesson_add(
         agent_uid,
         %{"skill_name" => skill_name, "content" => content, "evidence_job_ids" => evidence},
         state
       )
       when is_binary(skill_name) and is_binary(content) and is_list(evidence) do
    with {:ok, skill_name} <- SourceReader.normalize_skill_name(skill_name),
         {:ok, skill} <- Map.get(state.catalog, skill_name, {:error, :skill_not_found}),
         :ok <- validate_lesson_content(content, :dreaming),
         normalized = normalize_lesson_text(content),
         :ok <- reject_duplicate_lesson(state.active, skill_name, normalized),
         :ok <- reject_revoked_lesson(state.immunity, skill_name, normalized),
         {:ok, evidence_ids} <- validate_lesson_evidence(evidence, state.context),
         :ok <- enforce_round_cap(state.round_counts, skill_name),
         :ok <- enforce_active_cap(state.active, skill_name) do
      {:ok,
       %{
         agent_uid: agent_uid,
         skill_name: skill_name,
         content: String.trim(content),
         author_kind: "dreaming",
         evidence_job_ids: evidence_ids,
         checked_release: Map.fetch!(state.context, :checked_release),
         checked_skill_hash: skill.content_hash,
         review_after: DateTime.add(state.now, @lesson_term_days, :day)
       }}
    end
  end

  defp validate_lesson_add(_agent_uid, _add, _state), do: {:error, :invalid_add}

  defp validate_lesson_content(content, author_kind) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" ->
        {:error, :blank_content}

      Regex.match?(@lesson_url_pattern, trimmed) ->
        {:error, :content_contains_url}

      author_kind == :human ->
        :ok

      NativeKernel.estimate_o200k_base_tokens(trimmed) > @lesson_token_limit ->
        {:error, :content_too_long}

      match?({_text, [_hit | _rest]}, Sanitize.sanitize(trimmed)) ->
        {:error, :content_injection_suspect}

      true ->
        :ok
    end
  end

  defp validate_lesson_content(_content, _author_kind), do: {:error, :blank_content}

  defp reject_duplicate_lesson(active, skill_name, normalized) do
    case Map.get(active, skill_name) do
      %{normalized: set} ->
        if MapSet.member?(set, normalized), do: {:error, :duplicate_lesson}, else: :ok

      nil ->
        :ok
    end
  end

  defp reject_revoked_lesson(immunity, skill_name, normalized) do
    case Map.get(immunity, skill_name) do
      nil -> :ok
      set -> if MapSet.member?(set, normalized), do: {:error, :revoked_lesson}, else: :ok
    end
  end

  defp validate_lesson_evidence(evidence, context) do
    ids = Enum.uniq(evidence)
    bundle = Map.fetch!(context, :evidence_job_ids)
    human_input = Map.fetch!(context, :human_input_job_ids)

    cond do
      ids == [] or not Enum.all?(ids, &is_integer/1) ->
        {:error, :insufficient_evidence}

      not Enum.all?(ids, &MapSet.member?(bundle, &1)) ->
        {:error, :evidence_outside_bundle}

      length(ids) >= 2 ->
        {:ok, ids}

      MapSet.member?(human_input, hd(ids)) ->
        {:ok, ids}

      true ->
        {:error, :insufficient_evidence}
    end
  end

  defp enforce_round_cap(round_counts, skill_name) do
    if Map.get(round_counts, skill_name, 0) < @lesson_adds_per_skill,
      do: :ok,
      else: {:error, :adds_limit_reached}
  end

  defp enforce_active_cap(active, skill_name) do
    count = active |> Map.get(skill_name, %{count: 0}) |> Map.fetch!(:count)
    if count < @lesson_active_cap, do: :ok, else: {:error, :active_cap_reached}
  end

  defp reject_add(state, add, reason),
    do: %{state | rejected: [%{add: add, reason: reason} | state.rejected]}

  defp apply_lesson_review(agent_uid, review, state) do
    with {:ok, lesson_id, verdict, evidence, note} <- review_fields(review),
         {:ok, lesson} <- reviewable_lesson(state.repo, agent_uid, lesson_id),
         :ok <- validate_review_evidence(evidence, state.context) do
      apply_lesson_verdict(verdict, lesson, note, state)
    else
      {:error, reason} ->
        %{state | rejected: [%{review: review, reason: reason} | state.rejected]}
    end
  end

  defp review_fields(%{"lesson_id" => lesson_id, "verdict" => verdict} = review)
       when is_binary(lesson_id) and verdict in ["renew", "obsolete", "lapse"] do
    {:ok, lesson_id, verdict, Map.get(review, "evidence_job_ids", []), Map.get(review, "note")}
  end

  defp review_fields(_review), do: {:error, :invalid_review}

  defp reviewable_lesson(repo, agent_uid, lesson_id) do
    with {:ok, _uuid} <- Ecto.UUID.cast(lesson_id) do
      case repo.get_by(AgentSkillLesson, id: lesson_id, agent_uid: agent_uid) do
        nil -> {:error, :not_reviewable}
        %AgentSkillLesson{retired_at: %DateTime{}} -> {:error, :not_reviewable}
        %AgentSkillLesson{author_kind: "human"} -> {:error, :not_reviewable}
        %AgentSkillLesson{} = lesson -> {:ok, lesson}
      end
    else
      :error -> {:error, :invalid_review}
    end
  end

  defp validate_review_evidence(evidence, context) when is_list(evidence) do
    index = Map.fetch!(context, :index_job_ids)

    if Enum.all?(evidence, &(is_integer(&1) and MapSet.member?(index, &1))),
      do: :ok,
      else: {:error, :invalid_evidence}
  end

  defp validate_review_evidence(_evidence, _context), do: {:error, :invalid_evidence}

  defp apply_lesson_verdict("renew", lesson, _note, state) do
    if MapSet.member?(state.docket_ids, lesson.id) do
      attrs = %{
        review_after: DateTime.add(state.now, @lesson_term_days, :day),
        checked_release: Map.fetch!(state.context, :checked_release),
        checked_skill_hash: current_skill_hash(state.repo, lesson) || lesson.checked_skill_hash
      }

      case lesson |> AgentSkillLesson.changeset(attrs) |> state.repo.update() do
        {:ok, _lesson} -> %{state | renewed: state.renewed + 1}
        {:error, _changeset} -> reject_review(state, lesson, :invalid_review)
      end
    else
      reject_review(state, lesson, :outside_docket)
    end
  end

  defp apply_lesson_verdict("obsolete", lesson, note, state) do
    if is_binary(note) and String.trim(note) != "" do
      retire_lesson(lesson, "obsolete", state, &%{&1 | obsoleted: &1.obsoleted + 1})
    else
      reject_review(state, lesson, :missing_note)
    end
  end

  defp apply_lesson_verdict("lapse", lesson, _note, state) do
    if MapSet.member?(state.docket_ids, lesson.id) do
      retire_lesson(lesson, "lapsed", state, &%{&1 | lapsed: &1.lapsed + 1})
    else
      reject_review(state, lesson, :outside_docket)
    end
  end

  defp retire_lesson(lesson, reason, state, count) do
    attrs = %{retired_at: state.now, retire_reason: reason}

    case lesson |> AgentSkillLesson.changeset(attrs) |> state.repo.update() do
      {:ok, retired} ->
        count.(%{state | retired_skills: [retired.skill_name | state.retired_skills]})

      {:error, _changeset} ->
        reject_review(state, lesson, :invalid_review)
    end
  end

  defp reject_review(state, lesson, reason),
    do: %{
      state
      | rejected: [%{review: %{"lesson_id" => lesson.id}, reason: reason} | state.rejected]
    }

  defp current_skill_hash(repo, %AgentSkillLesson{} = lesson) do
    case repo.get_by(AgentSkill, agent_uid: lesson.agent_uid, skill_name: lesson.skill_name) do
      %AgentSkill{content_hash: content_hash} -> content_hash
      nil -> nil
    end
  end
end
