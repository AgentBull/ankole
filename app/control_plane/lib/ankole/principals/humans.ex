defmodule Ankole.Principals.Humans do
  @moduledoc false

  require Ash.Query

  alias Ankole.Principals
  alias Ankole.Principals.{HumanUser, Principal}
  alias Ankole.Repo

  @principal_profile_fields [:display_name, :avatar_url]
  @human_profile_fields [:email, :mobile, :job_title]

  def principal_profile_fields, do: @principal_profile_fields
  def human_profile_fields, do: @human_profile_fields

  def get_principal(uid) do
    with {:ok, normalized_uid} <- Principals.normalize_uid(uid) do
      case Principal |> Ash.Query.filter(uid == ^normalized_uid) |> Ankole.Ash.read_one!() do
        %Principal{} = principal -> {:ok, principal}
        nil -> {:error, :not_found}
      end
    end
  end

  def list_active_principals do
    Principal
    |> Ash.Query.filter(status == :active)
    |> Ash.Query.sort(uid: :asc)
    |> Ankole.Ash.read!()
  end

  def system_principal do
    case Principal |> Ash.Query.filter(type == :system) |> Ankole.Ash.read_one!() do
      %Principal{} = principal -> {:ok, principal}
      nil -> {:error, :system_principal_missing}
    end
  end

  def ensure_system_principal_in_tx() do
    case system_principal() do
      {:ok, principal} ->
        {:ok, principal}

      {:error, :system_principal_missing} ->
        insert_principal(%{
          uid: Ash.UUIDv7.generate(),
          type: :system,
          display_name: "System"
        })
    end
  end

  def create_human(attrs) when is_map(attrs),
    do: Repo.transact_top_level(fn -> create_human_in_tx(attrs) end)

  def create_human_in_tx(attrs, action \\ :create_in_tx) do
    with {:ok, principal} <- insert_principal(human_principal_attrs(attrs)),
         {:ok, human_user} <-
           insert_human_user(principal.uid, take_attrs(attrs, @human_profile_fields), action) do
      {:ok, %{principal: principal, human_user: human_user}}
    end
  end

  def update_human(uid, attrs) when is_map(attrs) do
    Repo.transact_top_level(fn ->
      update_human_in_tx(attrs |> Map.take([:display_name, :email]) |> Map.put(:uid, uid))
    end)
  end

  def update_human_in_tx(%{uid: uid} = changes) do
    attrs = Map.take(changes, [:display_name, :email])

    with {:ok, principal} <- lock_principal_in_tx(uid),
         :ok <- ensure_principal_type(principal, :human),
         {:ok, principal} <- update_principal_profile(principal, attrs),
         {:ok, human_user} <-
           upsert_human_user(principal.uid, take_attrs(attrs, @human_profile_fields)) do
      {:ok, %{principal | human_user: human_user}}
    end
  end

  def create_member_in_tx(attrs) do
    if is_nil(Principals.normalize_email(Map.get(attrs, :email))) do
      {:error, Ash.Error.Changes.InvalidArgument.exception(field: :email, message: "is required")}
    else
      with {:ok, %{principal: principal, human_user: human}} <- create_human_in_tx(attrs),
           do: {:ok, %{principal | human_user: human}}
    end
  end

  def lock_principal_in_tx(uid, mode \\ :update) do
    with {:ok, normalized_uid} <- Principals.normalize_uid(uid) do
      case Principal
           |> Ash.Query.filter(uid == ^normalized_uid)
           |> Ash.Query.lock(row_lock(mode))
           |> Ankole.Ash.read_one!(lock_identity: {"principals", normalized_uid}) do
        %Principal{} = principal -> {:ok, principal}
        nil -> {:error, :not_found}
      end
    end
  end

  def lock_active_human_in_tx(uid) do
    with {:ok, %Principal{type: :human, status: :active} = principal} <-
           lock_principal_in_tx(uid, :share),
         %HumanUser{} = human_user <-
           HumanUser
           |> Ash.Query.filter(principal_uid == ^principal.uid)
           |> Ash.Query.lock("FOR SHARE")
           |> Ankole.Ash.read_one!() do
      {:ok, %{principal: principal, human_user: human_user}}
    else
      {:ok, %Principal{}} -> {:error, :human_access_revoked}
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def lock_principals_in_tx(uids) when is_list(uids) do
    uids = uids |> Enum.uniq() |> Enum.sort()

    principals =
      Principal
      |> Ash.Query.filter(uid in ^uids)
      |> Ash.Query.sort(uid: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ankole.Ash.read!(lock_identity: {"principals", uids})

    {:ok, principals}
  end

  defp row_lock(:update), do: :for_update
  defp row_lock(:share), do: "FOR SHARE"
  defp row_lock(:key_share), do: "FOR KEY SHARE"

  # Every human and agent Principal owns one canonical Brain Object
  # (people/<uid> or agents/<uid>); the creation transaction keeps that
  # invariant so holder attribution and recall never miss a subject page.
  def insert_principal(attrs) do
    with :ok <- allow_guest_admission(attrs),
         {:ok, principal} <-
           Ankole.Ash.create(Principal, :create_in_tx, attrs),
         :ok <- ensure_canonical_brain_object(principal) do
      {:ok, principal}
    end
  end

  defp ensure_canonical_brain_object(%Principal{type: type} = principal)
       when type in [:human, :agent] do
    Ankole.Brain.Objects.ensure_canonical_object_in_tx(
      principal.uid,
      type,
      principal.display_name
    )
  end

  defp ensure_canonical_brain_object(%Principal{}), do: :ok

  def insert_human_user(principal_uid, attrs, action \\ :create_in_tx) do
    attrs = Map.put(attrs, :principal_uid, principal_uid)

    Ankole.Ash.create(HumanUser, action, attrs)
  end

  def update_principal_profile(principal, attrs) do
    profile_attrs = take_attrs(attrs, @principal_profile_fields)

    case map_size(profile_attrs) do
      0 ->
        {:ok, principal}

      _count ->
        Ankole.Ash.update(principal, :profile_in_tx, profile_attrs)
    end
  end

  def upsert_human_user(principal_uid, attrs) do
    case HumanUser
         |> Ash.Query.filter(principal_uid == ^principal_uid)
         |> Ankole.Ash.read_one!() do
      %HumanUser{} = human_user ->
        Ankole.Ash.update(human_user, :profile_in_tx, attrs)

      nil ->
        insert_human_user(principal_uid, attrs)
    end
  end

  def ensure_principal_type(%Principal{type: type}, type), do: :ok
  def ensure_principal_type(%Principal{}, :agent), do: {:error, :not_agent}
  def ensure_principal_type(%Principal{}, :human), do: {:error, :not_human}

  def human_principal_attrs(attrs, uid \\ Ash.UUIDv7.generate()) do
    attrs
    |> take_attrs([:membership | @principal_profile_fields])
    |> Map.put_new(:membership, :member)
    |> Map.merge(%{uid: uid, type: :human})
  end

  def change_human_membership(uid, membership) when membership in [:member, :guest] do
    Repo.transact_top_level(fn -> change_human_membership_in_tx(uid, membership) end)
  end

  def change_human_membership(_uid, _membership), do: {:error, :invalid_membership}

  def change_human_membership_in_tx(uid, membership) do
    Ankole.Pod.Pages.lock_tree()

    with :ok <- allow_guest_admission(%{membership: membership}),
         {:ok, principal} <- lock_principal_in_tx(uid),
         :ok <- ensure_principal_type(principal, :human),
         :ok <- membership_transition_allowed(principal, membership) do
      Ankole.Ash.update(principal, :membership_in_tx, %{membership: membership})
    end
  end

  defp membership_transition_allowed(principal, :guest) do
    admin_name = Ankole.AuthZ.Root.admin_group_name()

    with {:ok, groups} <- Ankole.AuthZ.list_principal_group_memberships(principal.uid) do
      if Enum.any?(groups, &(&1.name in [admin_name, "pod_admin"] and &1.built_in)),
        do: {:error, :admin_cannot_be_guest},
        else: :ok
    end
  end

  defp membership_transition_allowed(_principal, :member), do: :ok

  defp allow_guest_admission(attrs) do
    if Ankole.Attrs.get(attrs, :membership) in [:guest, "guest"] do
      with {:ok, enabled} <-
             Ankole.AppConfigure.get_tenant_by_key_in_tx("pod.allow_external_guests"),
           do: if(enabled, do: :ok, else: {:error, :external_guests_disabled})
    else
      :ok
    end
  end

  def required_text(attrs, key) do
    case fetch_attr(attrs, key) do
      {:ok, value} -> normalize_required_text(value)
      :error -> {:error, {:missing, key}}
    end
  end

  def normalize_required_text(value), do: Ankole.Attrs.required_text(value, :invalid_text)

  def take_attrs(attrs, keys) do
    Enum.reduce(keys, %{}, fn key, acc ->
      case fetch_attr(attrs, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  def fetch_attr(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(attrs, Atom.to_string(key))
    end
  end
end
