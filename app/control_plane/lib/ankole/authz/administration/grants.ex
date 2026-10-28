defmodule Ankole.AuthZ.Grants do
  @moduledoc """
  Permission grant writes that run in the caller's transaction.

  Writes that affect Pod access lock its tree before changing grants.
  """

  alias Ankole.Repo
  alias Ankole.AuthZ.Grant
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Input
  alias Ankole.AuthZ.Store

  require Ash.Query

  @console_admin_resource_patterns ["site_console:**", "tenant_console:**"]
  @console_admin_actions ~w(read update delete reset decrypt sync)

  def create(attrs), do: Repo.transact_top_level(fn -> create_permission_grant(attrs) end)
  def upsert(attrs), do: Repo.transact_top_level(fn -> upsert_permission_grant(attrs) end)
  def update(id, attrs), do: Repo.transact_top_level(fn -> update_permission_grant(id, attrs) end)
  def delete(id), do: Repo.transact_top_level(fn -> delete_permission_grant(id) end)

  def create_permission_grant(attrs) do
    :ok = Ankole.Repo.require_transaction()

    with {:ok, attrs} <- grant_attrs(attrs),
         :ok <- lock_pod(attrs),
         :ok <- allow_guest_share(attrs),
         {:ok, grant} <- Ankole.Ash.create(Grant, :create_in_tx, attrs),
         :ok <- refresh_targets([grant.target_page_id]) do
      {:ok, grant}
    end
  end

  def upsert_permission_grant(attrs) do
    :ok = Ankole.Repo.require_transaction()

    with {:ok, attrs} <- grant_attrs(attrs),
         :ok <- lock_pod(attrs),
         :ok <- allow_guest_share(attrs),
         {:ok, grant} <-
           Ankole.Ash.create(Grant, :upsert_in_tx, attrs,
             upsert_identity: permission_grant_identity(attrs)
           ),
         :ok <- refresh_targets([grant.target_page_id]) do
      {:ok, grant}
    end
  end

  def upsert_permission_grants([]), do: {:ok, []}

  def upsert_permission_grants(attrs_list) when is_list(attrs_list) do
    :ok = Ankole.Repo.require_transaction()

    with {:ok, normalized} <-
           attrs_list |> Enum.map(&grant_attrs/1) |> Ankole.Attrs.collect_results(),
         :ok <- lock_pod?(Enum.any?(normalized, &grant_affects_pod?/1)),
         :ok <- allow_guest_shares(normalized),
         {:ok, grants} <- upsert_grant_batches(normalized),
         :ok <- refresh_targets(Enum.map(grants, & &1.target_page_id)) do
      {:ok, grants}
    end
  end

  def update_permission_grant(%Grant{id: id}, attrs), do: update_permission_grant(id, attrs)

  def update_permission_grant(id, attrs) do
    with {:ok, grant, pod_locked?} <- lock_current_grant(id, attrs),
         :ok <- check_pod_lock(grant, attrs, pod_locked?) do
      update_current_grant(grant, attrs)
    end
  end

  defp update_current_grant(grant, attrs) do
    changes = Input.grant_attrs(attrs)
    attrs = Map.merge(Input.grant_attrs(Map.from_struct(grant)), changes)

    attrs =
      if Map.has_key?(changes, :resource_pattern) do
        Enum.reduce([:target_page_id, :target_scope], attrs, fn key, acc ->
          if Map.has_key?(changes, key), do: acc, else: Map.delete(acc, key)
        end)
      else
        attrs
      end

    with {:ok, attrs} <- grant_attrs(attrs),
         :ok <- allow_guest_share(attrs),
         {:ok, updated} <- Ankole.Ash.update(grant, :update_in_tx, attrs),
         :ok <- refresh_targets([grant.target_page_id, updated.target_page_id]) do
      {:ok, updated}
    end
  end

  def delete_permission_grant(id) do
    with {:ok, grant, pod_locked?} <- lock_current_grant(id, %{}),
         :ok <- check_pod_lock(grant, %{}, pod_locked?) do
      delete_current_grant(grant)
    end
  end

  defp delete_current_grant(grant) do
    with {:ok, deleted} <- Ankole.Ash.destroy(grant, :delete_in_tx),
         :ok <- refresh_targets([grant.target_page_id]) do
      {:ok, deleted}
    end
  end

  @doc "Deletes a group's grants and refreshes their Page anchors in the caller's transaction."
  def delete_group_grants_in_tx(group_id) do
    :ok = Repo.require_transaction()
    Ankole.Pod.Pages.lock_tree()
    query = Grant |> Ash.Query.filter(group_id == ^group_id)

    targets =
      query
      |> Ash.Query.filter(not is_nil(target_page_id))
      |> Ash.Query.select([:target_page_id])
      |> Ankole.Ash.read!()
      |> Enum.map(& &1.target_page_id)

    with {:ok, _} <- Ankole.Ash.destroy_where(query, :delete_in_tx),
         do: refresh_targets(targets)
  end

  def grant_affects_pod?(%{action: action, resource_pattern: pattern})
      when is_binary(action) and is_binary(pattern) do
    page_action?(action) or
      (action == "update" and
         Ankole.Kernel.authz_match_resource_pattern(pattern, "tenant_console:pod_space") == true)
  end

  def grant_affects_pod?(_attrs), do: false

  defp lock_pod(attrs), do: lock_pod?(grant_affects_pod?(attrs))
  defp lock_pod?(true), do: Ankole.Pod.Pages.lock_tree()
  defp lock_pod?(false), do: :ok

  defp lock_current_grant(id, attrs) do
    :ok = Ankole.Repo.require_transaction()

    with {:ok, current} <- Ankole.AuthZ.get_permission_grant(id),
         pod_locked? = mutation_affects_pod?(current, attrs),
         :ok <- lock_pod?(pod_locked?),
         {:ok, grant} <-
           Grant
           |> Ash.Query.filter(id == ^current.id)
           |> Ash.Query.lock(:for_update)
           |> Ankole.Ash.read_one(lock_identity: {"permission_grants", current.id}) do
      if grant, do: {:ok, grant, pod_locked?}, else: {:error, :not_found}
    end
  end

  defp mutation_affects_pod?(grant, attrs) do
    proposed = Map.merge(Map.from_struct(grant), Input.grant_attrs(attrs))
    grant_affects_pod?(grant) or grant_affects_pod?(proposed)
  end

  defp check_pod_lock(grant, attrs, false) do
    if mutation_affects_pod?(grant, attrs),
      do:
        {:error, Ankole.Errors.Invalid.Stale.exception(resource: Grant, filter: [id: grant.id])},
      else: :ok
  end

  defp check_pod_lock(_grant, _attrs, true), do: :ok

  defp refresh_targets(ids) do
    ids
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      case Ankole.Pod.Access.refresh_anchor_in_tx(id) do
        :ok -> {:cont, :ok}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp allow_guest_shares(normalized) do
    normalized
    |> Enum.uniq_by(&{Map.get(&1, :principal_uid), page_action?(Map.get(&1, :action))})
    |> Enum.reduce_while(:ok, fn attrs, :ok ->
      case allow_guest_share(attrs) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp upsert_grant_batches(normalized) do
    normalized
    |> Enum.chunk_by(&permission_grant_identity/1)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      identity = permission_grant_identity(hd(batch))

      case Ankole.Ash.create_all(deduplicate_grant_batch(batch, identity), Grant, :upsert_in_tx,
             upsert_identity: identity
           ) do
        {:ok, grants} -> {:cont, {:ok, Enum.reverse(grants, acc)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, grants} -> {:ok, Enum.reverse(grants)}
      {:error, _reason} = error -> error
    end
  end

  defp deduplicate_grant_batch(batch, identity) do
    batch
    |> Enum.reverse()
    |> Enum.uniq_by(&grant_natural_key(&1, identity))
    |> Enum.reverse()
  end

  defp grant_natural_key(attrs, :principal_rule) do
    uid =
      case Ankole.PrincipalKey.normalize_optional(Map.get(attrs, :principal_uid)) do
        {:ok, normalized} -> normalized
        _invalid -> Map.get(attrs, :principal_uid)
      end

    {uid, Map.get(attrs, :resource_pattern), Map.get(attrs, :action),
     Map.get(attrs, :condition, "true")}
  end

  defp grant_natural_key(attrs, :userset_rule) do
    {Map.get(attrs, :source_page_id), Map.get(attrs, :source_action),
     Map.get(attrs, :resource_pattern), Map.get(attrs, :action),
     Map.get(attrs, :condition, "true")}
  end

  defp grant_natural_key(attrs, :group_rule) do
    {Map.get(attrs, :group_id), Map.get(attrs, :resource_pattern), Map.get(attrs, :action),
     Map.get(attrs, :condition, "true")}
  end

  defp allow_guest_share(%{principal_uid: uid, action: action})
       when is_binary(uid) and action in ~w(page_view page_write_records page_edit page_manage) do
    with {:ok, principal} <- Ankole.Principals.get_principal(uid) do
      if principal.membership == :guest do
        with {:ok, enabled} <-
               Ankole.AppConfigure.get_tenant_by_key_in_tx("pod.allow_external_guests"),
             do: if(enabled, do: :ok, else: {:error, :external_guests_disabled})
      else
        :ok
      end
    end
  end

  defp allow_guest_share(_attrs), do: :ok

  @doc """
  Creates a grant for the Console operator. The Pod writes the grants of its
  page actions, so the operator cannot create one.
  """
  def create_operator_grant(attrs) do
    with :ok <- refuse_page_action(Map.get(attrs, :action)) do
      create_permission_grant(attrs)
    end
  end

  @doc """
  Updates a grant for the Console operator. A Pod page grant keeps the resource
  pattern, the action, and the condition that the Pod wrote; only its
  description can change.
  """
  def update_operator_grant(id, attrs) do
    with {:ok, grant, pod_locked?} <- lock_current_grant(id, attrs),
         :ok <- refuse_page_action(Map.get(attrs, :action)),
         :ok <- keep_page_grant(grant, attrs),
         :ok <- check_pod_lock(grant, attrs, pod_locked?) do
      update_current_grant(grant, attrs)
    end
    |> Ankole.Errors.not_found([:not_found], Grant)
  end

  @doc "Deletes a grant for the Console operator. A Pod page grant is refused."
  def delete_operator_grant(id) do
    with {:ok, grant, pod_locked?} <- lock_current_grant(id, %{}),
         false <- page_action?(grant.action),
         :ok <- check_pod_lock(grant, %{}, pod_locked?) do
      delete_current_grant(grant)
    else
      true -> {:error, :page_grant}
      error -> error
    end
    |> Ankole.Errors.not_found([:not_found], Grant)
  end

  def upsert_console_admin_grants(%Group{} = admin_group) do
    upsert_admin_grants(admin_group, @console_admin_resource_patterns)
  end

  def upsert_pod_admin_grants(%Group{} = admin_group),
    do: upsert_admin_grants(admin_group, ["tenant_console:**"])

  defp upsert_admin_grants(admin_group, patterns) do
    attrs_list =
      for pattern <- patterns,
          action <- @console_admin_actions do
        %{
          group_id: admin_group.id,
          resource_pattern: pattern,
          action: action,
          description: "Built-in console administrator grant",
          metadata: %{"built_in" => "console_admin"}
        }
      end

    upsert_permission_grants(attrs_list)
  end

  defp grant_attrs(attrs) do
    attrs = Input.grant_attrs(attrs)

    result =
      case Input.fetch_attr(attrs, :group_name) do
        {:ok, group_name} ->
          with {:ok, group} <- Store.fetch_group(group_name) do
            {:ok, attrs |> Map.delete(:group_name) |> Map.put(:group_id, group.id)}
          end

        :error ->
          {:ok, attrs}
      end

    with {:ok, attrs} <- result, do: normalize_target(attrs)
  end

  defp normalize_target(%{action: action, resource_pattern: pattern} = attrs)
       when action in ~w(page_view page_write_records page_edit page_manage) and
              is_binary(pattern) do
    case Regex.run(
           ~r/\Apod:\*\*:([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}):(\*\*|page)\z/,
           pattern
         ) do
      [_, id, suffix] ->
        scope = if suffix == "**", do: "container", else: "self"
        {:ok, attrs |> Map.put_new(:target_page_id, id) |> Map.put_new(:target_scope, scope)}

      _ ->
        {:ok, attrs}
    end
  end

  defp normalize_target(attrs), do: {:ok, attrs}

  defp page_action?(action), do: action in Ankole.Pod.Access.page_actions()

  defp refuse_page_action(action) do
    if page_action?(action),
      do: {:error, invalid_argument(:action, "#{action} is written by the Pod")},
      else: :ok
  end

  defp keep_page_grant(%Grant{action: action}, attrs) do
    with true <- page_action?(action),
         [_ | _] = fields <-
           Enum.filter([:resource_pattern, :action, :condition], &Map.has_key?(attrs, &1)) do
      {:error, Enum.map(fields, &invalid_argument(&1, "cannot change on a Pod page grant"))}
    else
      _no_change -> :ok
    end
  end

  defp invalid_argument(field, message),
    do: Ash.Error.Changes.InvalidArgument.exception(field: field, message: message)

  defp permission_grant_identity(attrs) do
    case Ankole.PrincipalKey.normalize_optional(Map.get(attrs, :principal_uid)) do
      {:ok, uid} when is_binary(uid) ->
        :principal_rule

      _not_principal_owned ->
        if(Map.get(attrs, :source_page_id), do: :userset_rule, else: :group_rule)
    end
  end
end
