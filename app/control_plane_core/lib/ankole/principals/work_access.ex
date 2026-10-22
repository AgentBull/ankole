defmodule Ankole.Principals.WorkAccess do
  @moduledoc "Human authorization retained by each durable work owner."
  import Ecto.Query
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.Signals.Signal
  alias Ankole.Work.Owner

  @fields [:authorization_kind, :human_uid, :human_access_version]
  def list_for_human(uid) do
    Enum.flat_map(Owner.entries(), fn {kind, schema} ->
      Repo.across_tenants(fn ->
        Repo.all(
          from(w in schema,
            where: w.human_uid == ^uid,
            order_by: [desc: w.inserted_at],
            limit: 50
          )
        )
      end)
      |> Enum.map(&projection(kind, &1))
    end)
  end

  def list_unresolved do
    Enum.flat_map(Owner.entries(), fn {kind, schema} ->
      # The work belongs to the selected tenant; its recorded Human can belong
      # to another tenant or no longer exist after that tenant was deleted.
      query =
        from(w in schema,
          left_join: human in Principal,
          on: human.uid == w.human_uid,
          where:
            w.authorization_kind == "review_required" or
              (w.authorization_kind == "human" and
                 (is_nil(human.uid) or human.type != :human or human.status != :active or
                    is_nil(w.human_access_version) or
                    human.access_version != w.human_access_version)),
          order_by: w.inserted_at,
          limit: 50,
          select: w
        )

      query = Owner.unresolved_query(query, schema)

      tenant_id = Repo.tenant_id!()

      # The root must stay in the current tenant. The author join uses a global
      # UID because deleting or moving the author's tenant does not move work.
      Repo.across_tenants(fn ->
        Repo.all(from(w in query, where: w.tenant_id == ^tenant_id))
      end)
      |> Enum.map(&projection(kind, &1))
    end)
  end

  def classify(kind, id, human_uid, actor_uid, reason) do
    with schema when not is_nil(schema) <- Owner.schema(kind),
         {:ok, id} <- cast_id(schema, id),
         true <- is_binary(reason) and String.trim(reason) != "" do
      Ankole.Repo.transact(fn repo ->
        authorization = if is_nil(human_uid), do: service(), else: from_sender(repo, human_uid)
        subject_uid = human_uid || actor_uid.uid
        subject = Repo.across_tenants(fn -> repo.get(Principal, subject_uid) end)

        with %Principal{} <- subject,
             true <- is_nil(human_uid) or authorization.authorization_kind == "human",
             true <-
               is_nil(human_uid) or subject.tenant_id == Repo.tenant_id!() or
                 subject.uid == actor_uid.uid,
             :ok <- check_in_tx(repo, authorization),
             %{} = work <-
               repo.one(from(w in schema, where: w.id == ^id, lock: "FOR UPDATE"),
                 lock_identity: {schema.__schema__(:source), id}
               ),
             true <- reauthorizable?(kind, work),
             true <- work.authorization_kind != "human" or not is_nil(human_uid),
             previous_authorization = fields(work),
             {:ok, work} <- Ankole.Ash.update(work, :reauthorize, authorization),
             {:ok, _} <-
               Repo.with_tenant(subject.tenant_id, fn ->
                 Ankole.Ash.create(Ankole.Principals.AccessEvent, :record_in_tx, %{
                   principal_uid: subject_uid,
                   actor: actor_uid,
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
                     authorization_kind: authorization.authorization_kind,
                     previous_authorization: previous_authorization
                   }
                 })
               end) do
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
    if Ecto.Type.type(schema.__schema__(:type, :id)) in [:id, :integer] do
      Ankole.ModelIntegerID.parse(id)
    else
      Ecto.UUID.cast(id)
    end
  end

  defp projection(kind, work) do
    status = to_string(work.status)

    %{
      kind: kind,
      id: to_string(work.id),
      agent_uid: work.agent_uid,
      status: status,
      authorization_kind: work.authorization_kind,
      human_uid: work.human_uid,
      human_access_version: work.human_access_version,
      can_reauthorize: reauthorizable?(kind, work),
      updated_at: work.updated_at
    }
  end

  defp reauthorizable?(_kind, %{authorization_kind: "review_required"} = work),
    do: Owner.reauthorizable_state?(work)

  # Reauthorization does not revive work. Cron retains a paused rule with a
  # separate resume operation; the other revoked work must be replaced.
  defp reauthorizable?("cron", %{authorization_kind: "human", status: :paused} = work),
    do: not valid_subject_now?(work)

  defp reauthorizable?(_kind, _work), do: false

  def fields(%{authorization_kind: _} = source), do: Map.take(source, @fields)

  def fields(_),
    do: %{authorization_kind: "review_required", human_uid: nil, human_access_version: nil}

  def from_sender(repo, uid) when is_binary(uid) do
    case Repo.across_tenants(fn -> repo.get(Principal, uid) end) do
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

  def valid_now?(work) do
    Ankole.Tenants.accepting_work?(Repo.tenant_id!()) and valid_subject_now?(work)
  end

  defp valid_subject_now?(%{
         authorization_kind: "human",
         human_uid: uid,
         human_access_version: version
       }),
       do: Repo.across_tenants(fn -> Ankole.Principals.HumanAccess.check(uid, version) end) == :ok

  defp valid_subject_now?(%{authorization_kind: "service"}), do: true
  defp valid_subject_now?(_), do: false

  defp from_event(repo, id) when is_binary(id), do: fields(repo.get(Signal, id))
  defp from_event(_repo, _id), do: fields(nil)

  def inherit(repo, attrs) do
    source_id = Ankole.Attrs.get_truthy(attrs, :source_signal_id)
    created_by = Ankole.Attrs.get_truthy(attrs, :created_by) || %{}

    authorization =
      cond do
        is_binary(source_id) ->
          from_event(repo, source_id)

        is_binary(created_by["signal_id"]) ->
          from_event(repo, created_by["signal_id"])

        is_binary(created_by["principal_uid"]) ->
          case Ankole.ActorRef.cast(created_by["principal_uid"]) do
            {:ok, reference} -> from_sender(repo, reference.uid)
            :error -> fields(nil)
          end

        true ->
          fields(nil)
      end

    merge(attrs, authorization)
  end

  def merge(attrs, source) do
    authorization = fields(source)

    if Enum.any?(Map.keys(attrs), &is_binary/1),
      do:
        Map.merge(
          attrs,
          Ankole.Attrs.normalize_external_attrs(authorization)
        ),
      else: Map.merge(attrs, authorization)
  end

  def check_in_tx(repo, %{
        authorization_kind: "human",
        human_uid: uid,
        human_access_version: version
      }) do
    case lock_authorizer(repo, uid) do
      %Principal{type: :human, status: :active, access_version: ^version} -> :ok
      _ -> {:error, :human_access_revoked}
    end
  end

  def check_in_tx(_repo, %{authorization_kind: "service"}), do: :ok
  def check_in_tx(_repo, _work), do: {:error, :work_authorization_review_required}

  def lock_authorizers_in_tx(repo, works) do
    uids =
      works
      |> Enum.flat_map(fn
        %{authorization_kind: "human", human_uid: uid} when is_binary(uid) -> [uid]
        _ -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    Repo.across_tenants(fn ->
      repo.all(
        from(principal in Principal,
          where: principal.uid in ^uids,
          order_by: principal.uid,
          lock: "FOR UPDATE"
        ),
        lock_identity: {"principals", uids}
      )
    end)

    :ok
  end

  defp lock_authorizer(repo, uid) do
    Repo.across_tenants(fn ->
      repo.one(from(p in Principal, where: p.uid == ^uid, lock: "FOR UPDATE"),
        lock_identity: {"principals", uid}
      )
    end)
  end

  def check_record_in_tx(repo, schema, id) do
    case repo.get(schema, id) do
      nil -> {:error, :work_not_found}
      work -> check_in_tx(repo, work)
    end
  end

  def check_attrs_in_tx(repo, attrs) do
    check_in_tx(repo, Map.new(@fields, &{&1, Ankole.Attrs.get_truthy(attrs, &1)}))
  end
end
