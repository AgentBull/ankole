defmodule Ankole.Principals.WorkAccess do
  @moduledoc "Human authorization retained by each durable work owner."
  import Ecto.Query
  alias Ankole.Principals.Principal
  alias Ankole.SignalsGateway.ActorEvent

  @fields [:authorization_kind, :human_uid, :human_access_version]
  @owners %{
    "actor_event" => Ankole.SignalsGateway.ActorEvent,
    "cron" => Ankole.Schedule.Schemas.CronSchedule,
    "scheduled_event" => Ankole.Schedule.Schemas.ScheduledEvent,
    "background_job" => Ankole.BackgroundAgentJobs.Schemas.Job,
    "workflow" => Ankole.Workflow.Schemas.Run,
    "automation_job" => Ankole.AutomationJobs.Schemas.Job
  }

  def list_for_human(uid) do
    Enum.flat_map(@owners, fn {kind, schema} ->
      Ankole.Repo.all(
        from w in schema, where: w.human_uid == ^uid, order_by: [desc: w.inserted_at], limit: 50
      )
      |> Enum.map(&projection(kind, &1))
    end)
  end

  def list_unresolved do
    Enum.flat_map(@owners, fn {kind, schema} ->
      query =
        from w in schema,
          where: w.authorization_kind == "review_required",
          order_by: w.inserted_at,
          limit: 50

      query =
        case kind do
          "actor_event" -> from w in query, where: is_nil(w.completed_at)
          "cron" -> from w in query, where: w.status in ["active", "paused"]
          "scheduled_event" -> from w in query, where: w.status in ["scheduled", "failed"]
          "background_job" -> from w in query, where: w.status in ["queued", "waiting_on_user"]
          "workflow" -> from w in query, where: w.status == "running"
          "automation_job" -> from w in query, where: w.status == "active"
        end

      query |> Ankole.Repo.all() |> Enum.map(&projection(kind, &1))
    end)
  end

  def classify(kind, id, human_uid, actor_uid, reason) do
    with schema when not is_nil(schema) <- Map.get(@owners, kind),
         {:ok, id} <- cast_id(schema, id),
         true <- is_binary(reason) and String.trim(reason) != "" do
      Ankole.Repo.transact(fn repo ->
        authorization = if is_nil(human_uid), do: service(), else: from_sender(repo, human_uid)
        subject = repo.get(Principal, human_uid || actor_uid)

        with %Principal{} <- subject,
             true <- is_nil(human_uid) or authorization.authorization_kind == "human",
             :ok <- check_in_tx(repo, authorization),
             %{authorization_kind: "review_required"} = work <-
               repo.one(from w in schema, where: w.id == ^id, lock: "FOR UPDATE"),
             {:ok, work} <- work |> Ecto.Changeset.change(authorization) |> repo.update(),
             {:ok, _} <-
               repo.insert(
                 Ecto.Changeset.change(%Ankole.Principals.AccessEvent{}, %{
                   principal_uid: human_uid || actor_uid,
                   actor_uid: actor_uid,
                   operation_id: Ankole.Kernel.gen_uuid_v7(),
                   source: "work_review",
                   action: "classify_work",
                   reason: reason,
                   access_version: subject.access_version,
                   previous_status: subject.status,
                   status: subject.status,
                   details: %{
                     kind: kind,
                     id: to_string(id),
                     authorization_kind: authorization.authorization_kind
                   }
                 })
               ) do
          {:ok, projection(kind, work)}
        else
          {:error, _} = error -> error
          _ -> {:error, :work_review_changed}
        end
      end)
    else
      _ -> {:error, :invalid_work_review}
    end
  end

  defp cast_id(schema, id) do
    if schema.__schema__(:type, :id) == :id do
      case Integer.parse(to_string(id)) do
        {value, ""} when value > 0 -> {:ok, value}
        _ -> :error
      end
    else
      Ecto.UUID.cast(id)
    end
  end

  defp projection(kind, work) do
    %{
      kind: kind,
      id: to_string(work.id),
      agent_uid: work.agent_uid,
      status:
        Map.get(work, :status) ||
          if(Map.get(work, :completed_at), do: "completed", else: work.input_state),
      authorization_kind: work.authorization_kind,
      human_uid: work.human_uid,
      human_access_version: work.human_access_version,
      updated_at: work.updated_at
    }
  end

  def fields(%{authorization_kind: _} = source), do: Map.take(source, @fields)

  def fields(_),
    do: %{authorization_kind: "review_required", human_uid: nil, human_access_version: nil}

  def from_sender(repo, uid) when is_binary(uid) do
    case repo.get(Principal, uid) do
      %Principal{type: :human, access_version: version} ->
        %{authorization_kind: "human", human_uid: uid, human_access_version: version}

      %Principal{type: :agent, status: :active} ->
        service()

      _ ->
        fields(nil)
    end
  end

  def from_sender(_repo, _uid), do: fields(nil)
  def service, do: %{authorization_kind: "service", human_uid: nil, human_access_version: nil}

  def from_observation(_repo, %{"principal_uid" => uid, "human_access_version" => version})
      when is_binary(uid) and is_integer(version),
      do: %{authorization_kind: "human", human_uid: uid, human_access_version: version}

  def from_observation(repo, %{"principal_uid" => uid}) do
    case from_sender(repo, uid) do
      %{authorization_kind: "service"} = authorization -> authorization
      _ -> fields(nil)
    end
  end

  def from_observation(_repo, _author), do: fields(nil)

  def valid_now?(%{authorization_kind: "human", human_uid: uid, human_access_version: version}),
    do: Ankole.Principals.HumanAccess.check(uid, version) == :ok

  def valid_now?(%{authorization_kind: "service"}), do: true
  def valid_now?(_), do: false

  def from_event(repo, id) when is_binary(id), do: fields(repo.get(ActorEvent, id))
  def from_event(_repo, _id), do: fields(nil)

  def inherit(repo, attrs) do
    source_id = value(attrs, :source_actor_event_id)
    created_by = value(attrs, :created_by) || %{}

    authorization =
      cond do
        is_binary(source_id) -> from_event(repo, source_id)
        is_binary(created_by["actor_event_id"]) -> from_event(repo, created_by["actor_event_id"])
        is_binary(created_by["principal_uid"]) -> from_sender(repo, created_by["principal_uid"])
        true -> fields(nil)
      end

    merge(attrs, authorization)
  end

  def merge(attrs, source) do
    authorization = fields(source)

    if Enum.any?(Map.keys(attrs), &is_binary/1),
      do:
        Map.merge(
          attrs,
          Map.new(authorization, fn {key, value} -> {Atom.to_string(key), value} end)
        ),
      else: Map.merge(attrs, authorization)
  end

  def check_in_tx(repo, %{
        authorization_kind: "human",
        human_uid: uid,
        human_access_version: version
      }) do
    case repo.one(from p in Principal, where: p.uid == ^uid, lock: "FOR UPDATE") do
      %Principal{type: :human, status: :active, access_version: ^version} -> :ok
      _ -> {:error, :human_access_revoked}
    end
  end

  def check_in_tx(_repo, %{authorization_kind: "service"}), do: :ok
  def check_in_tx(_repo, _work), do: {:error, :work_authorization_review_required}

  def check_record_in_tx(repo, schema, id) do
    case repo.get(schema, id) do
      nil -> {:error, :work_not_found}
      work -> check_in_tx(repo, work)
    end
  end

  def check_attrs_in_tx(repo, attrs) do
    check_in_tx(repo, Map.new(@fields, &{&1, value(attrs, &1)}))
  end

  defp value(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
