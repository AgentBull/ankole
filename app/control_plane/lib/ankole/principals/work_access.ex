defmodule Ankole.Principals.WorkAccess do
  @moduledoc """
  Human authorization retained by each durable work owner.

  The recorded Human belongs to the work tenant. Reads and locks use that
  tenant context; the audit actor may belong to a different tenant.
  """
  require Ash.Query
  alias Ankole.Principals.Principal
  alias Ankole.Repo
  alias Ankole.Work.Owner

  @fields [:authorization_kind, :human_uid, :human_access_version]
  @list_limit 50
  @review_batch 200

  def list_for_human(uid) do
    Enum.flat_map(Owner.entries(), fn {kind, schema} ->
      schema
      |> Ash.Query.filter(human_uid == ^uid)
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(@list_limit)
      |> Ankole.Ash.read!()
      |> Enum.map(&projection(kind, &1))
    end)
  end

  # Work review uses the selected tenant and its current members.
  def list_unresolved do
    Enum.flat_map(Owner.entries(), fn {kind, schema} ->
      schema
      |> Ash.Query.filter(authorization_kind in ["review_required", "human"])
      |> Owner.unresolved_query(schema)
      |> Ash.Query.sort(inserted_at: :asc, id: :asc)
      |> unresolved(0, [])
      |> Enum.map(&projection(kind, &1))
    end)
  end

  defp unresolved(query, offset, found) do
    page =
      query
      |> Ash.Query.offset(offset)
      |> Ash.Query.limit(@review_batch)
      |> Ankole.Ash.read!()

    authorizers = page |> human_uids() |> read_principals() |> Map.new(&{&1.uid, &1})
    found = found ++ Enum.reject(page, &authorized?(&1, authorizers))

    cond do
      length(found) >= @list_limit -> Enum.take(found, @list_limit)
      length(page) < @review_batch -> found
      true -> unresolved(query, offset + @review_batch, found)
    end
  end

  defp authorized?(
         %{authorization_kind: "human", human_uid: uid, human_access_version: version},
         authorizers
       )
       when is_integer(version) do
    match?(
      %Principal{type: :human, status: :active, access_version: ^version},
      Map.get(authorizers, uid)
    )
  end

  defp authorized?(_work, _authorizers), do: false

  def classify(kind, id, human_uid, actor_uid, reason) do
    with schema when not is_nil(schema) <- Owner.schema(kind),
         {:ok, id} <- cast_id(schema, id),
         true <- is_binary(reason) and String.trim(reason) != "" do
      Repo.transact_top_level(fn ->
        classify_in_tx(kind, id, human_uid, actor_uid, reason)
      end)
    else
      _ -> {:error, :invalid_work_review}
    end
  end

  @doc false
  def classify_in_tx(kind, id, human_uid, actor_uid, reason) do
    schema = Owner.schema(kind)
    authorization = if is_nil(human_uid), do: service(), else: from_sender(human_uid)
    subject_uid = human_uid || actor_uid.uid

    subject =
      if human_uid,
        do: read_principal(human_uid),
        else: Repo.with_tenant(actor_uid.tenant_id, fn -> read_principal(actor_uid.uid) end)

    with %Principal{} <- subject,
         true <- is_nil(human_uid) or authorization.authorization_kind == "human",
         :ok <- check_in_tx(authorization),
         %{} = work <- Owner.lock(schema, id),
         :ok <- check_execution_target(work.agent_uid, authorization),
         true <- reauthorizable?(kind, work),
         true <- work.authorization_kind != "human" or not is_nil(human_uid),
         previous_authorization = fields(work),
         {:ok, work} <- Ankole.Ash.update(work, :reauthorize, authorization),
         {:ok, _} <-
           Repo.with_tenant(subject.tenant_id, fn ->
             Ankole.Ash.create(Ankole.Principals.AccessEvent, :record_in_tx, %{
               principal_uid: subject_uid,
               actor: actor_uid,
               operation_id: Ash.UUIDv7.generate(),
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

  def from_sender(uid) when is_binary(uid) do
    case read_principal(uid) do
      %Principal{type: :human, access_version: version} ->
        %{authorization_kind: "human", human_uid: uid, human_access_version: version}

      %Principal{type: :agent, status: :active} ->
        case Ankole.Principals.authority_uid(uid) do
          ^uid -> service()
          owner_uid -> from_sender(owner_uid)
        end

      _ ->
        fields(nil)
    end
  end

  def from_sender(_uid), do: fields(nil)
  def service, do: %{authorization_kind: "service", human_uid: nil, human_access_version: nil}

  def check_execution_target(uid, %{authorization_kind: "service"}) when is_binary(uid) do
    case Ankole.Principals.get_agent_record!(uid) do
      %{type: :personal_assistant} -> {:error, :personal_assistant_requires_human_work}
      _ -> :ok
    end
  end

  def check_execution_target(_uid, _authorization), do: :ok

  def from_observation(%{"principal_uid" => uid, "human_access_version" => version})
      when is_binary(uid) and is_integer(version),
      do: %{authorization_kind: "human", human_uid: uid, human_access_version: version}

  def from_observation(%{"principal_uid" => uid}) do
    case from_sender(uid) do
      %{authorization_kind: "service"} = authorization -> authorization
      _ -> fields(nil)
    end
  end

  def from_observation(_author), do: fields(nil)

  def valid_now?(work) do
    Ankole.Tenants.accepting_work?(Repo.tenant_id!()) and valid_subject_now?(work)
  end

  defp valid_subject_now?(%{
         authorization_kind: "human",
         human_uid: uid,
         human_access_version: version
       }),
       do: Ankole.Principals.HumanAccess.check(uid, version) == :ok

  defp valid_subject_now?(%{authorization_kind: "service"}), do: true
  defp valid_subject_now?(_), do: false

  defp from_event(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> fields(Owner.get(Owner.schema("signal"), id))
      :error -> fields(nil)
    end
  end

  defp from_event(_id), do: fields(nil)

  def inherit(attrs) do
    source_id = Ankole.Attrs.get_truthy(attrs, :source_signal_id)
    created_by = Ankole.Attrs.get_truthy(attrs, :created_by) || %{}

    authorization =
      cond do
        is_binary(source_id) ->
          from_event(source_id)

        is_binary(created_by["signal_id"]) ->
          from_event(created_by["signal_id"])

        is_binary(created_by["principal_uid"]) ->
          case Ankole.ActorRef.cast(created_by["principal_uid"]) do
            {:ok, reference} -> from_sender(reference.uid)
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

  def check_in_tx(%{
        authorization_kind: "human",
        human_uid: uid,
        human_access_version: version
      }) do
    case lock_principals([uid]) do
      [%Principal{type: :human, status: :active, access_version: ^version}] -> :ok
      _ -> {:error, :human_access_revoked}
    end
  end

  def check_in_tx(%{authorization_kind: "service"}), do: :ok
  def check_in_tx(_work), do: {:error, :work_authorization_review_required}

  def lock_authorizers_in_tx(works) do
    works
    |> Enum.flat_map(fn
      %{authorization_kind: "human", human_uid: uid} when is_binary(uid) -> [uid]
      _ -> []
    end)
    |> lock_principals()

    :ok
  end

  def check_record_in_tx(schema, id) do
    case Owner.get(schema, id) do
      nil -> {:error, :work_not_found}
      work -> check_in_tx(work)
    end
  end

  def check_attrs_in_tx(attrs) do
    check_in_tx(Map.new(@fields, &{&1, Ankole.Attrs.get_truthy(attrs, &1)}))
  end

  defp human_uids(works) do
    for %{authorization_kind: "human", human_uid: uid} <- works,
        is_binary(uid),
        uniq: true,
        do: uid
  end

  defp read_principal(uid) do
    case read_principals([uid]) do
      [principal] -> principal
      [] -> nil
    end
  end

  defp read_principals([]), do: []

  defp read_principals(uids) do
    Principal
    |> Ash.Query.filter(uid in ^uids)
    |> Ankole.Ash.read!()
  end

  # Principal locks have the first rank of the work lock order; the UID order
  # keeps the locks of concurrent callers in one order.
  defp lock_principals(uids) do
    uids = uids |> Enum.uniq() |> Enum.sort()

    Principal
    |> Ash.Query.filter(uid in ^uids)
    |> Ash.Query.sort(uid: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read!(lock_identity: {"principals", uids})
  end
end
