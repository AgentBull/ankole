defmodule Ankole.Conversations.Route do
  @moduledoc "Resolves the durable source and long-lived recipient of a turn."

  require Ash.Query

  alias Ankole.AIGateway
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Conversations.Conversation
  alias Ankole.Signals.Signal
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run

  @type source :: %{
          signal_id: Ecto.UUID.t(),
          binding_name: String.t(),
          conversation_id: String.t() | nil,
          provider_thread_id: String.t() | nil,
          provider_message_id: String.t() | nil
        }

  @doc "Returns the creation source Message through Job wakeups and continuations."
  def source_message_id(turn), do: source_message([turn], MapSet.new(), :origin)

  @doc "Returns the current causal native Human request, not attached or delegated text."
  def human_request(turn) do
    case human_request_message(turn) do
      %{request: request} ->
        request

      nil ->
        nil
    end
  end

  @doc "Returns the current Main input from its admitted root and actually injected steers."
  def current_input_signal_id(run) do
    [run.signal_id | Map.get(run, :steer_event_ids, [])]
    |> Enum.reduce(run.signal_id, fn id, current_id ->
      if direct_human_message(id, run.agent_uid), do: id, else: current_id
    end)
  end

  @doc "Selects a newly applied Human steer without allowing older summaries to reset intent."
  def applied_human_source(job, events) do
    current = human_request_message(%{job_id: job.id, agent_uid: job.agent_uid})

    events
    |> Enum.reduce({current, nil}, fn event, {latest, selected} ->
      message =
        case event do
          %Signal{
            producer: :kernel,
            source: "control-plane://background-agent-job",
            type: "command.steer",
            data: %{"source_signal_id" => id}
          } ->
            direct_human_message(id, job.agent_uid)

          _ ->
            nil
        end

      if newer_human?(message, latest), do: {message, event.id}, else: {latest, selected}
    end)
    |> elem(1)
  end

  defp human_request_message(turn) do
    source_message(
      [Map.take(turn, [:signal_id, :agent_uid]), turn],
      MapSet.new(),
      :instructions
    )
  end

  defp direct_human_message(id, uid) do
    case agent_signal(id, uid) do
      %Signal{producer: :kernel} = source -> native_human_request(source)
      _ -> nil
    end
  end

  defp native_human_request(source) do
    message = Ankole.Conversations.message_for_signal(source)
    text = get_in(source.data, ["entry", "text"]) || source.data["text"]

    case message do
      %Ankole.Conversations.Message{origin: :native, author_type: :human, kind: :message}
      when is_binary(text) and text != "" ->
        %{signal: source, request: %{"message_id" => message.id, "text" => text}}

      _ ->
        nil
    end
  end

  defp newer_human?(nil, _current), do: false
  defp newer_human?(_message, nil), do: true

  defp newer_human?(%{signal: source}, %{signal: current}) do
    if source.session_id == current.session_id do
      {source.queue_sequence, source.id} > {current.queue_sequence, current.id}
    else
      # Queue sequences are Session-local. Across Sessions use the immutable
      # accepted version time; a provider retry is not a new Human request.
      {DateTime.to_unix(source.occurred_at, :microsecond), source.id} >
        {DateTime.to_unix(current.occurred_at, :microsecond), current.id}
    end
  end

  defp select_source_message(source, _rest, _visited, :origin), do: source.message_id

  defp select_source_message(source, rest, visited, :instructions) do
    message = native_human_request(source)
    current = source_message(rest, visited, :instructions)
    if newer_human?(message, current), do: message, else: current
  end

  # The creation source stays fixed. Only execution instructions follow the
  # CP's latest applied Human steer reference.
  defp source_message([%{job_id: id, agent_uid: uid} | rest], visited, mode)
       when is_integer(id) do
    if MapSet.member?(visited, {:job, id}) do
      source_message(rest, visited, mode)
    else
      visited = MapSet.put(visited, {:job, id})

      case agent_job(id, uid) do
        %Job{} = job ->
          applied =
            if mode == :instructions,
              do: [%{signal_id: job.metadata["applied_source_signal_id"], agent_uid: uid}],
              else: []

          source_message(
            applied ++
              [
                %{signal_id: job.source_signal_id, agent_uid: uid},
                %{job_id: job.continued_from_job_id, agent_uid: uid}
                | rest
              ],
            visited,
            mode
          )

        _ ->
          source_message(rest, visited, mode)
      end
    end
  end

  defp source_message([%{signal_id: id, agent_uid: uid} | rest], visited, mode)
       when is_binary(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         false <- MapSet.member?(visited, {:signal, id}) do
      visited = MapSet.put(visited, {:signal, id})

      case agent_signal(id, uid) do
        %Signal{message_id: id} = source when is_binary(id) ->
          select_source_message(source, rest, visited, mode)

        %Signal{
          producer: :kernel,
          source: "control-plane://background-agent-job",
          type: "command.steer",
          data: %{"source_signal_id" => source_id}
        } ->
          # A Main summary is not a new Human request. It must not reset an
          # already-applied Human steer to the Main turn's earlier wakeup.
          source = agent_signal(source_id, uid)

          case source && Ankole.Conversations.message_for_signal(source) do
            %Ankole.Conversations.Message{origin: :native, author_type: :human} ->
              source_message([%{signal_id: source_id, agent_uid: uid} | rest], visited, mode)

            _ ->
              source_message(rest, visited, mode)
          end

        %Signal{producer: :kernel, type: type, data: %{"job_id" => job_id}}
        when type in [
               "background_agent_job.dispatch",
               "background_agent_job.completed",
               "background_agent_job.failed",
               "background_agent_job.input_undeliverable",
               "background_agent_job.waiting"
             ] ->
          source_message([%{job_id: job_id, agent_uid: uid} | rest], visited, mode)

        _ ->
          source_message(rest, visited, mode)
      end
    else
      _ -> source_message(rest, visited, mode)
    end
  end

  defp source_message([_turn | rest], visited, mode), do: source_message(rest, visited, mode)
  defp source_message([], _visited, _mode), do: nil

  @doc """
  Resolves the durable reply route for one turn.
  """
  @spec source(%{signal_id: Ecto.UUID.t()}) ::
          {:ok, source()} | {:error, :reply_route_not_in_turn}
  def source(%{signal_id: signal_id}) when is_binary(signal_id) do
    case Ankole.Signals.get_signal!(signal_id) do
      %Signal{} = event ->
        {:ok,
         %{
           signal_id: event.id,
           binding_name: event.reply_binding_name,
           conversation_id: event.conversation_id,
           provider_thread_id: event.provider_thread_id,
           provider_message_id: event.provider_message_id
         }}

      nil ->
        {:error, :reply_route_not_in_turn}
    end
  end

  def source(_turn), do: {:error, :reply_route_not_in_turn}

  @doc """
  Resolves the session that can receive a webhook or automation result after
  the calling Job or Workflow task ends. The caller remains the source of
  authorization and provenance. A resolved reply route replaces only the
  delivery destination, not that source.
  """
  @spec long_lived_owner(String.t(), String.t()) ::
          {:ok, %{session_id: String.t(), reply_route: map() | nil}}
          | {:error, :long_lived_reply_owner_not_found}
  def long_lived_owner(agent_uid, session_id)
      when is_binary(agent_uid) and is_binary(session_id) and session_id != "" do
    resolve_owner(agent_uid, session_id, nil, MapSet.new())
  end

  def long_lived_owner(_agent_uid, _session_id),
    do: {:error, :long_lived_reply_owner_not_found}

  @doc "Returns the current source with its long-lived delivery destination."
  def long_lived_source(turn) do
    with {:ok, source} <- source(turn),
         {:ok, owner} <- long_lived_owner(turn.agent_uid, turn.session_id) do
      route =
        owner.reply_route ||
          %{
            "binding_name" => source.binding_name,
            "conversation_id" => source.conversation_id,
            "provider_thread_id" => source.provider_thread_id,
            "provider_message_id" => source.provider_message_id
          }

      {:ok, %{source: source, owner_session_id: owner.session_id, reply_route: route}}
    end
  end

  defp resolve_owner(agent_uid, session_id, route, visited)
       when is_binary(session_id) and session_id != "" do
    if MapSet.member?(visited, session_id) do
      {:error, :long_lived_reply_owner_not_found}
    else
      resolve_session_owner(
        Ankole.Sessions.Key.parse(session_id),
        agent_uid,
        session_id,
        route,
        MapSet.put(visited, session_id)
      )
    end
  end

  defp resolve_owner(_agent_uid, _session_id, _route, _visited),
    do: {:error, :long_lived_reply_owner_not_found}

  defp resolve_session_owner({:job, _}, agent_uid, session_id, _route, visited) do
    with {:ok, job_id} <- BackgroundAgentJobs.parse_job_session_id(session_id),
         %Job{} = job <- agent_job(job_id, agent_uid),
         conversation_id when is_binary(conversation_id) <-
           Map.get(job.metadata || %{}, "owner_conversation_id"),
         {:ok, %{conversation_key: owner_session_id}} <-
           AIGateway.get_conversation(agent_uid, conversation_id, include_ended: true),
         true <- owner_session_id == job.owner_session_id,
         %{} = reply_route <- job.reply_route do
      resolve_owner(agent_uid, owner_session_id, reply_route, visited)
    else
      _missing -> {:error, :long_lived_reply_owner_not_found}
    end
  end

  defp resolve_session_owner({:workflow_task, _}, agent_uid, session_id, _route, visited) do
    with {:ok, call_id} <- Workflow.parse_task_session_id(session_id),
         %AgentCall{} = call <- agent_call(call_id, agent_uid),
         %Run{} = run <- agent_run(call.run_id, agent_uid),
         %{} = reply_route <- run.reply_route do
      resolve_owner(agent_uid, run.owner_session_id, reply_route, visited)
    else
      _missing -> {:error, :long_lived_reply_owner_not_found}
    end
  end

  defp resolve_session_owner(_kind, agent_uid, session_id, route, _visited) do
    native_id = native_conversation_id(agent_uid, session_id)

    case route do
      nil when not is_nil(native_id) ->
        {:ok, %{session_id: session_id, reply_route: %{"conversation_id" => native_id}}}

      nil ->
        {:ok, %{session_id: session_id, reply_route: nil}}

      %{"conversation_id" => id} when id == native_id and not is_nil(id) ->
        {:ok, %{session_id: session_id, reply_route: route}}

      %{"binding_name" => binding_name} when is_binary(binding_name) and binding_name != "" ->
        if AIGateway.conversation_exists_by_key?(agent_uid, session_id) do
          {:ok, %{session_id: session_id, reply_route: route}}
        else
          {:error, :long_lived_reply_owner_not_found}
        end

      _invalid ->
        {:error, :long_lived_reply_owner_not_found}
    end
  end

  def snapshot(turn) do
    case Ankole.Signals.get_signal!(turn.signal_id) do
      %Signal{} = event ->
        route =
          %{
            "binding_name" => event.reply_binding_name,
            "conversation_id" => event.conversation_id,
            "provider_thread_id" => event.provider_thread_id,
            "provider_message_id" => event.provider_message_id
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        case Signal.scheduled_delivery_snapshot(event) do
          %{} = delivery -> Map.put(route, "delivery", delivery)
          _ -> route
        end

      _ ->
        %{}
    end
  end

  defp native_conversation_id(agent_uid, key) do
    with {:conversation, id} <- Ankole.Sessions.Key.parse(key),
         %Conversation{} <-
           Conversation
           |> Ash.Query.filter(
             id == ^id and kind == :native and
               exists(
                 Ankole.Conversations.Participant,
                 conversation_id == parent(id) and principal_uid == ^agent_uid and role == :agent
               )
           )
           |> Ash.Query.select([:id])
           |> Ankole.Ash.read_one!() do
      id
    else
      _ -> nil
    end
  end

  defp agent_signal(id, uid),
    do: first(Ankole.Signals.list_signals!(query: [filter: [id: id, agent_uid: uid]]))

  defp agent_job(id, uid),
    do: first(Ankole.BackgroundAgentJobs.list_jobs!(query: [filter: [id: id, agent_uid: uid]]))

  defp agent_call(id, uid),
    do: first(Ankole.Workflow.list_agent_calls!(query: [filter: [id: id, agent_uid: uid]]))

  defp agent_run(id, uid),
    do: first(Ankole.Workflow.list_runs!(query: [filter: [id: id, agent_uid: uid]]))

  defp first([record]), do: record
  defp first([]), do: nil
end
