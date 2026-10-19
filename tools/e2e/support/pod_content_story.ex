defmodule Ankole.E2E.PodContentStory do
  @moduledoc "Real model work completion and public evidence for Pod user stories."

  import Ecto.Query
  import ExUnit.Assertions
  import ExUnit.Callbacks
  import Ankole.E2E.Harness
  import Ankole.E2E.WaitHelpers, only: [deadline: 1, wait_until: 2, wait_for_signal_completed: 3]

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Conversations
  alias Ankole.Pod.Pages
  alias Ankole.Principals.Agent
  alias Ankole.Repo
  alias Ankole.Signals.Signal

  @coding_model "minimax/minimax-m3"
  @story_timeout 3_600_000
  @job_timeout 1_200_000

  def start!(tenant) do
    assert :ok = Ankole.Tenants.ensure_scaffold(tenant)
    cleanup_committed_fixtures_on_exit!()

    ctx =
      start_worker_e2e_stack!(real_llm_api_key: openrouter_api_key!())
      |> Map.put(:story_deadline, deadline(@story_timeout))

    configure_browser_origin!(ctx.server_port, tenant)
    owner = Repo.get!(Agent, ctx.agent.uid).owner_principal_uid

    assert {:ok, _} =
             ModelProfiles.put_model_profile(ctx.agent.uid, "coding", %{
               provider_id: ctx.provider_id,
               model: @coding_model
             })

    assert {:ok, _} =
             Ankole.AuthZ.upsert_permission_grant(%{
               principal_uid: owner,
               resource_pattern: "pod:space",
               action: "update",
               condition: "true"
             })

    assert {:ok, _} = Pages.space_agent(owner, ctx.agent.uid, "edit")
    {ctx, owner}
  end

  def await_delivery(owner, conversation_id, message_id, agent_uid, page_id) do
    case wait_until(deadline(180_000), fn ->
           {:ok, detail} = Conversations.get(owner, conversation_id)
           if delivered_after?(detail, message_id, agent_uid, page_id), do: detail
         end) do
      {:ok, detail} ->
        detail

      :timeout ->
        {:ok, detail} = Conversations.get(owner, conversation_id)
        detail
    end
  end

  def delivered_after?(detail, message_id, agent_uid, page_id) do
    case Enum.find(detail.messages, &(&1.id == message_id and &1.author_type == :human)) do
      %{seq: requested_at} ->
        Enum.any?(detail.messages, fn message ->
          message.seq > requested_at and message.author_type == :agent and
            message.author_uid == agent_uid and
            Enum.any?(message.links, &(&1["kind"] == "page" and &1["id"] == page_id))
        end)

      nil ->
        false
    end
  end

  defdelegate delivery_evidence(ctx, completion, detail, delivered?),
    to: Ankole.E2E.PodContentEvidence

  @doc "Checks named facts in one sentence or a direct pronoun continuation."
  def assert_named_facts!(text, facts) do
    labels =
      facts
      |> Enum.map_join("|", fn {name, _value} -> "(?:#{name})" end)
      |> Regex.compile!("iu")

    for {name, value} <- facts do
      values = fact_matches(text, value)

      associated =
        Enum.any?(fact_matches(text, name), fn label ->
          Enum.any?(values, &adjacent_fact?(text, label, &1, labels))
        end)

      assert associated, "The report does not associate #{name} with #{value}"
    end
  end

  defp fact_matches(text, pattern) do
    for [match] <-
          Regex.scan(Regex.compile!(pattern, "iu"), text, return: :index, capture: :first),
        do: match
  end

  defp adjacent_fact?(text, first, second, labels) do
    [{start, size}, {finish, _}] = Enum.sort([first, second])

    if start + size <= finish do
      between = binary_part(text, start + size, finish - start - size)

      String.length(between) <= 160 and not Regex.match?(labels, between) and
        not Regex.match?(~r/[\r\n;；!?！？]/u, between) and
        same_fact_sentences?(between, elem(first, 0) < elem(second, 0))
    else
      false
    end
  end

  defp same_fact_sentences?(between, label_first?) do
    case Regex.split(~r/。|(?<!\d)\.|\.(?!\d)/u, between) do
      [_sentence] ->
        true

      [_sentence, continuation] ->
        label_first? and Regex.match?(~r/^\s*(?:It\b|They\b|它们?)/iu, continuation)

      _ ->
        false
    end
  end

  def complete_request!(ctx, input, options \\ []) do
    preserve_request_evidence_on_exit!(ctx, input)

    assert {:ok, _} =
             wait_for_signal_completed(
               ctx.container,
               input.id,
               min(deadline(180_000), ctx.story_deadline)
             )

    jobs = jobs_from_signal(ctx, input)

    if Keyword.get(options, :require_job, true) do
      assert jobs != [], "The real Human request did not start an Agent Job"
    end

    completion = finish_request_jobs!(ctx, jobs, Repo.reload!(input))
    Ankole.E2E.PodContentEvidence.request(ctx, input)
    completion
  rescue
    error in ExUnit.AssertionError ->
      Ankole.E2E.PodContentEvidence.request(ctx, input)
      reraise error, __STACKTRACE__
  end

  defp preserve_request_evidence_on_exit!(ctx, input) do
    tenant_id = Repo.tenant_id!()

    on_exit(fn ->
      Repo.put_tenant_id(tenant_id)
      Ankole.E2E.PodContentEvidence.request(ctx, input)
    end)
  end

  defp finish_request_jobs!(ctx, jobs, last_completion, seen \\ MapSet.new())

  defp finish_request_jobs!(_ctx, [], last_completion, _seen), do: last_completion

  defp finish_request_jobs!(ctx, [job | pending], last_completion, seen) do
    completion = complete_job!(ctx, job, last_completion)
    seen = MapSet.put(seen, job.id)

    next =
      (pending ++ jobs_from_signal(ctx, completion))
      |> Enum.uniq_by(& &1.id)
      |> Enum.reject(&MapSet.member?(seen, &1.id))

    finish_request_jobs!(ctx, next, completion, seen)
  end

  defp complete_job!(ctx, job, last_completion) do
    assert job.human_uid == last_completion.human_uid
    assert is_binary(job.source_tool_call_id)
    finished = finish_job!(ctx, job)

    assert {:ok, %Signal{} = completion} =
             wait_until(min(deadline(60_000), ctx.story_deadline), fn ->
               Repo.one(
                 from s in Signal,
                   where:
                     s.agent_uid == ^ctx.agent.uid and
                       s.session_id == ^last_completion.session_id,
                   where:
                     s.source_event_id ==
                       ^"background_agent_job:#{finished.id}:#{finished.status}:#{finished.attempts}"
               )
             end)

    assert {:ok, _} =
             wait_for_signal_completed(
               ctx.container,
               completion.id,
               ctx.story_deadline
             )

    Repo.reload!(completion)
  end

  defp jobs_from_signal(ctx, signal) do
    query =
      from job in Job,
        where: job.agent_uid == ^ctx.agent.uid and job.source_signal_id == ^signal.id,
        order_by: job.id

    query =
      case signal.data["successor_job_id"] do
        id when is_integer(id) ->
          or_where(query, [job], job.agent_uid == ^ctx.agent.uid and job.id == ^id)

        _ ->
          query
      end

    Repo.all(query)
  end

  defp finish_job!(ctx, job) do
    assert {:ok, %Signal{}} =
             wait_until(min(deadline(60_000), ctx.story_deadline), fn ->
               Repo.one(
                 from s in Signal,
                   where: s.agent_uid == ^ctx.agent.uid,
                   where: s.session_id == ^BackgroundAgentJobs.job_session_id(job.id),
                   where: s.type == "background_agent_job.dispatch"
               )
             end)

    assert {:ok, %Job{} = finished} =
             wait_until(min(deadline(@job_timeout), ctx.story_deadline), fn ->
               case Repo.get!(Job, job.id) do
                 %Job{status: status} = current
                 when status in ["succeeded", "failed", "stopped"] ->
                   current

                 _ ->
                   nil
               end
             end)

    finished
  end

  defp configure_browser_origin!(port, tenant) do
    previous = Application.fetch_env!(:ankole, AnkoleWeb.Endpoint)
    origin = AnkoleWeb.PodURL.origin(%{scheme: :http, port: port}, tenant)
    configured = Keyword.put(previous, :check_origin, [origin])
    Application.put_env(:ankole, AnkoleWeb.Endpoint, configured)
    :ok = AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, configured}], [])

    on_exit(fn ->
      Application.put_env(:ankole, AnkoleWeb.Endpoint, previous)
      :ok = AnkoleWeb.Endpoint.config_change([{AnkoleWeb.Endpoint, previous}], [])
    end)
  end
end
