defmodule Ankole.Principals.Humans do
  @moduledoc false

  require Ash.Query

  alias Ankole.IdentityProviders.LocalPassword
  alias Ankole.Principals
  alias Ankole.Principals.{HumanUser, LocalCredential, Principal}
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

    with :ok <- require_local_identity_provider(),
         :ok <- keep_email(attrs),
         {:ok, principal} <- lock_principal_in_tx(uid),
         :ok <- ensure_principal_type(principal, :human),
         {:ok, principal} <- update_principal_profile(principal, attrs),
         {:ok, human_user} <-
           upsert_human_user(principal.uid, take_attrs(attrs, @human_profile_fields)) do
      {:ok, %{principal | human_user: human_user}}
    end
  end

  def create_local_user(attrs, must_change_password)
      when is_map(attrs) and is_boolean(must_change_password) do
    Repo.assert_outside_transaction!()
    initial_password = LocalCredential.generate_initial_password()

    with {:ok, password_hash} <- LocalPassword.hash_password(initial_password),
         {:ok, principal} <-
           Repo.transact_top_level(fn ->
             create_local_user_in_tx(%{
               email: Map.get(attrs, :email),
               display_name: Map.get(attrs, :display_name),
               must_change_password: must_change_password,
               initial_password: initial_password,
               password_hash: password_hash
             })
           end) do
      {:ok,
       %{
         principal: principal,
         human_user: principal.human_user,
         initial_password: principal.__metadata__.initial_password
       }}
    end
  end

  def create_local_user_in_tx(args) do
    with :ok <- require_local_identity_provider(),
         {:ok, %{principal: principal, human_user: human_user}} <-
           create_human_in_tx(Map.take(args, [:email, :display_name]), :create_local_in_tx),
         {:ok, _credential} <-
           put_local_credential_in_tx(
             principal.uid,
             args.password_hash,
             Map.get(args, :must_change_password) != false
           ) do
      {:ok,
       principal
       |> Map.put(:human_user, human_user)
       |> Ash.Resource.put_metadata(:initial_password, args.initial_password)}
    end
  end

  # Each local-account write needs an enabled local identity provider, so that
  # no credential is made that no login path accepts.
  defp require_local_identity_provider do
    if LocalPassword.enabled?(), do: :ok, else: {:error, :local_identity_provider_disabled}
  end

  defp keep_email(%{email: nil}),
    do: {:error, Ash.Error.Changes.Required.exception(field: :email, type: :argument)}

  defp keep_email(_attrs), do: :ok

  def fetch_local_login(email) do
    case HumanUser
         |> Ash.Query.filter(email == ^email)
         |> Ash.Query.load(principal: [:local_credential])
         |> Ankole.Ash.read_one!() do
      %HumanUser{principal: %Principal{} = principal} = human_user ->
        {:ok,
         %{principal: principal, human_user: human_user, credential: principal.local_credential}}

      _missing ->
        {:error, :not_found}
    end
  end

  def put_local_credential(uid, password_hash, must_change_password) do
    Repo.transact_top_level(fn ->
      put_local_password_in_tx(uid, password_hash, must_change_password)
    end)
  end

  def put_local_password_in_tx(uid, password_hash, must_change_password) do
    with :ok <- ensure_local_login_human(uid),
         do: put_local_credential_in_tx(uid, password_hash, must_change_password)
  end

  def put_local_credential_in_tx(uid, password_hash, must_change_password) do
    attrs = %{password_hash: password_hash, must_change_password: must_change_password}

    case LocalCredential |> Ash.Query.filter(principal_uid == ^uid) |> Ankole.Ash.read_one!() do
      %LocalCredential{} = credential ->
        Ankole.Ash.update(credential, :set_password_in_tx, attrs)

      nil ->
        Ankole.Ash.create(LocalCredential, :create_in_tx, Map.put(attrs, :principal_uid, uid))
    end
  end

  def complete_forced_password_change(uid, password_hash, credential_version) do
    Repo.transact_top_level(fn ->
      complete_forced_password_change_in_tx(uid, password_hash, credential_version)
    end)
  end

  def complete_forced_password_change_in_tx(uid, password_hash, credential_version) do
    with %LocalCredential{must_change_password: true} = credential <-
           LocalCredential
           |> Ash.Query.filter(principal_uid == ^uid)
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one!(),
         true <- LocalCredential.version(credential) == credential_version do
      Ankole.Ash.update(credential, :set_password_in_tx, %{
        password_hash: password_hash,
        must_change_password: false
      })
    else
      _no_matching_change -> {:error, :password_change_not_required}
    end
  end

  defp ensure_local_login_human(uid) do
    case HumanUser |> Ash.Query.filter(principal_uid == ^uid) |> Ankole.Ash.read_one!() do
      %HumanUser{email: email} when is_binary(email) ->
        :ok

      %HumanUser{} ->
        {:error, :email_missing}

      nil ->
        case get_principal(uid) do
          {:ok, %Principal{}} -> {:error, :not_human}
          {:error, _missing} -> {:error, :not_found}
        end
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
    with {:ok, principal} <-
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
  def ensure_principal_type(%Principal{type: :human}, :agent), do: {:error, :not_agent}
  def ensure_principal_type(%Principal{type: :agent}, :human), do: {:error, :not_human}

  def human_principal_attrs(attrs, uid \\ Ash.UUIDv7.generate()) do
    attrs
    |> take_attrs(@principal_profile_fields)
    |> Map.merge(%{uid: uid, type: :human})
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
