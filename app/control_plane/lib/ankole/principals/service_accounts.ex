defmodule Ankole.Principals.ServiceAccounts do
  @moduledoc """
  Lifecycle and lookup operations for tenant Service Accounts.

  Unlike human and agent creation, `ensure_in_tx/1` never acquires the rank-2
  `page-tree` lock or provisions private Drive roots or Brain `people/` pages,
  so inbound IM bot admission and Applet lifecycle operations remain lightweight
  and respect `Ankole.LockOrder`.
  """

  require Ash.Query

  alias Ankole.Principals
  alias Ankole.Principals.{Principal, ServiceAccount, SystemServices}

  @applet_uid_regex ~r/\Asvc_applet_[0-9a-f]{32}\z/
  @bot_uid_regex ~r/\Abot_[a-z0-9][a-z0-9._+-]{0,88}\z/

  @spec applet_uid(String.t()) :: String.t()
  def applet_uid(page_id) when is_binary(page_id) do
    "svc_applet_" <> (page_id |> String.downcase() |> String.replace("-", ""))
  end

  @spec applet_display_name(String.t() | nil, String.t() | nil) :: String.t()
  def applet_display_name(title, name \\ nil) do
    base =
      [title, name]
      |> Enum.find_value("Applet", fn candidate ->
        if is_binary(candidate) and String.trim(candidate) != "",
          do: String.trim(candidate)
      end)

    base <> " (Applet)"
  end

  @spec bot_uid(String.t(), String.t()) :: String.t()
  def bot_uid(provider, external_id) when is_binary(provider) and is_binary(external_id) do
    raw =
      "#{provider}_#{external_id}"
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._+-]+/, "_")
      |> String.trim("_")

    cond do
      raw == "" ->
        "bot_" <>
          String.slice(Base.encode16(:crypto.hash(:sha256, external_id), case: :lower), 0, 24)

      byte_size("bot_" <> raw) <= 92 ->
        "bot_" <> raw

      true ->
        digest =
          :crypto.hash(:sha256, "#{provider}:#{external_id}")
          |> Base.encode16(case: :lower)
          |> binary_part(0, 12)

        "bot_" <> binary_part(raw, 0, 74) <> "_" <> digest
    end
  end

  @spec applet_service_uid?(term()) :: boolean()
  def applet_service_uid?(uid) when is_binary(uid), do: Regex.match?(@applet_uid_regex, uid)
  def applet_service_uid?(_uid), do: false

  @spec applet_page_id(term()) :: {:ok, String.t()} | :error
  def applet_page_id("svc_applet_" <> hex) when byte_size(hex) == 32 do
    with {:ok, raw} <- Base.decode16(hex, case: :lower),
         {:ok, uuid} <- Ecto.UUID.load(raw) do
      {:ok, uuid}
    else
      _ -> :error
    end
  end

  def applet_page_id(_uid), do: :error

  @spec external_bot_uid?(term()) :: boolean()
  def external_bot_uid?(uid) when is_binary(uid), do: Regex.match?(@bot_uid_regex, uid)
  def external_bot_uid?(_uid), do: false

  @spec valid_system_uid?(term()) :: boolean()
  def valid_system_uid?(uid) when is_binary(uid) do
    SystemServices.registered?(uid) or applet_service_uid?(uid) or external_bot_uid?(uid)
  end

  def valid_system_uid?(_uid), do: false

  @spec reserved_non_system_uid?(term()) :: boolean()
  def reserved_non_system_uid?(uid) when is_binary(uid) do
    normalized = String.downcase(String.trim(uid))
    valid_system_uid?(normalized) or String.starts_with?(normalized, ["svc_", "bot_"])
  end

  def reserved_non_system_uid?(_uid), do: false

  @spec singleton_kind(String.t()) :: :brain | :applet | :platform
  def singleton_kind("ankole_brain"), do: :brain
  def singleton_kind("ankole_applets"), do: :applet
  def singleton_kind(_uid), do: :platform

  @spec fetch(String.t()) :: {:ok, ServiceAccount.t()} | {:error, :service_account_not_found}
  def fetch(uid) when is_binary(uid) do
    with {:ok, normalized} <- Principals.normalize_uid(uid),
         %ServiceAccount{} = account <-
           ServiceAccount
           |> Ash.Query.filter(uid == ^normalized)
           |> Ash.Query.load(:principal)
           |> Ankole.Ash.read_one!() do
      {:ok, account}
    else
      _ -> {:error, :service_account_not_found}
    end
  end

  @spec lock_in_tx(String.t()) :: ServiceAccount.t() | nil
  def lock_in_tx(uid) when is_binary(uid) do
    ServiceAccount
    |> Ash.Query.filter(uid == ^uid)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!()
  end

  @doc """
  Idempotently creates or loads a Service Account and its backing `:system` Principal
  inside the caller's transaction without taking the `page-tree` lock.
  """
  @spec ensure_in_tx(map()) ::
          {:ok, %{principal: Principal.t(), service_account: ServiceAccount.t()}}
          | {:error, term()}
  def ensure_in_tx(%{uid: uid, kind: kind} = attrs)
      when is_binary(uid) and kind in [:brain, :applet, :external_bot, :platform] do
    with {:ok, uid} <- Principals.normalize_uid(uid),
         true <- valid_system_uid?(uid),
         {:ok, principal} <- ensure_principal_row_in_tx(uid, attrs),
         {:ok, service_account} <- ensure_service_row_in_tx(uid, kind, attrs) do
      {:ok, %{principal: principal, service_account: service_account}}
    else
      false -> {:error, :unknown_system_principal}
      {:error, _reason} = error -> error
    end
  end

  @spec ensure_applet_in_tx(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, %{principal: Principal.t(), service_account: ServiceAccount.t()}}
          | {:error, term()}
  def ensure_applet_in_tx(page_id, title, name \\ nil) when is_binary(page_id) do
    uid = applet_uid(page_id)
    display_name = applet_display_name(title, name)

    with {:ok, %{principal: principal, service_account: account}} <-
           ensure_in_tx(%{
             uid: uid,
             kind: :applet,
             applet_page_id: page_id,
             display_name: display_name
           }),
         {:ok, principal} <- maybe_sync_display_name_in_tx(principal, display_name) do
      {:ok, %{principal: principal, service_account: account}}
    end
  end

  @spec lock_applet_in_tx(String.t()) :: :ok
  def lock_applet_in_tx(page_id) when is_binary(page_id) do
    :ok = Ankole.Repo.require_transaction()

    case Ecto.UUID.cast(page_id) do
      {:ok, id} ->
        uid = applet_uid(id)

        _ =
          Principal
          |> Ash.Query.filter(uid == ^uid and type == :system)
          |> Ash.Query.lock("FOR NO KEY UPDATE")
          |> Ankole.Ash.read_one!(lock_identity: {"principals", uid})

        :ok

      :error ->
        :ok
    end
  end

  def lock_applet_in_tx(_page_id), do: :ok

  @spec sync_applet_title_in_tx(String.t(), String.t() | nil, String.t() | nil) :: :ok
  def sync_applet_title_in_tx(page_id, title, name \\ nil) when is_binary(page_id) do
    uid = applet_uid(page_id)
    display_name = applet_display_name(title, name)

    case Principal
         |> Ash.Query.filter(uid == ^uid and type == :system)
         |> Ash.Query.lock("FOR NO KEY UPDATE")
         |> Ankole.Ash.read_one!(lock_identity: {"principals", uid}) do
      %Principal{} = principal ->
        {:ok, _} = maybe_sync_display_name_in_tx(principal, display_name)
        :ok

      nil ->
        :ok
    end
  end

  @spec delete_applet_in_tx(String.t()) :: :ok
  def delete_applet_in_tx(page_id) when is_binary(page_id), do: delete_applets_in_tx([page_id])

  @spec delete_applets_in_tx([String.t()]) :: :ok
  def delete_applets_in_tx([]), do: :ok

  def delete_applets_in_tx(page_ids) when is_list(page_ids) do
    :ok = Ankole.Repo.require_transaction()
    uids = page_ids |> Enum.map(&applet_uid/1) |> Enum.uniq() |> Enum.sort()

    found_uids =
      Principal
      |> Ash.Query.filter(uid in ^uids and type == :system)
      |> Ash.Query.select([:uid])
      |> Ash.Query.sort(uid: :asc)
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.uid)

    if found_uids == [] do
      :ok
    else
      Ankole.Pod.lock_tree_in_tx()

      locked_uids =
        Principal
        |> Ash.Query.filter(uid in ^found_uids and type == :system)
        |> Ash.Query.sort(uid: :asc)
        |> Ash.Query.lock(:for_update)
        |> Ankole.Ash.read!(lock_identity: {"principals", found_uids})
        |> Enum.map(& &1.uid)

      if locked_uids != [] do
        Enum.each(locked_uids, &Ankole.AuthZ.Grants.delete_principal_resource_grants_in_tx/1)

        {:ok, _} =
          Principal
          |> Ash.Query.filter(uid in ^locked_uids and type == :system)
          |> Ankole.Ash.destroy_where(:delete_in_tx)
      end

      :ok
    end
  end

  defp ensure_principal_row_in_tx(uid, attrs) do
    case Principal |> Ash.Query.filter(uid == ^uid) |> Ankole.Ash.read_one!() do
      %Principal{type: :system} = principal ->
        {:ok, principal}

      %Principal{} ->
        {:error, :principal_type_conflict}

      nil ->
        Ankole.Ash.create(Principal, :create_in_tx, %{
          uid: uid,
          type: :system,
          display_name: Map.get(attrs, :display_name) || uid,
          avatar_url: Map.get(attrs, :avatar_url)
        })
    end
  end

  defp ensure_service_row_in_tx(uid, kind, attrs) do
    case ServiceAccount |> Ash.Query.filter(uid == ^uid) |> Ankole.Ash.read_one!() do
      %ServiceAccount{} = account ->
        {:ok, account}

      nil ->
        Ankole.Ash.create(ServiceAccount, :create_in_tx, %{
          uid: uid,
          kind: kind,
          applet_page_id: Map.get(attrs, :applet_page_id),
          options: Map.get(attrs, :options) || %{}
        })
    end
  end

  defp maybe_sync_display_name_in_tx(%Principal{display_name: current} = principal, desired)
       when current == desired,
       do: {:ok, principal}

  defp maybe_sync_display_name_in_tx(%Principal{} = principal, desired),
    do: Ankole.Ash.update(principal, :profile_in_tx, %{display_name: desired})
end
