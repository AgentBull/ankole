defmodule Ankole.IdentityProviders.Directory do
  @moduledoc """
  Control-plane write side of identity-provider directory sync.

  Identity adapters normalize provider payloads; this module owns every
  Principal/AuthZ write those normalizations feed: directory-group ensure and
  disable with their external bindings, group-member replacement, and the
  subject-upsert plus membership-sync pair. Persisted group naming and the
  binding lifecycle (`active`/`disabled`) are decided here once instead of per
  adapter.
  """

  alias Ankole.AuthZ
  alias Ankole.Logging
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Principals

  defmodule Group do
    @moduledoc """
    One provider directory group normalized by an identity adapter.

    `kind` is the provider-facing noun baked into persisted group names and
    binding metadata (`"usergroup"`, `"entra_group"`, `"google_group"`,
    `"department"`); changing it for an existing provider would orphan its
    groups. `provider_metadata` carries the adapter's branded metadata submap
    (for example `%{"slack" => %{...}}`) merged into the group metadata as-is.
    """

    @enforce_keys [:external_id, :kind, :display_name]
    defstruct [:external_id, :kind, :display_name, :parent_external_id, provider_metadata: %{}]

    @type t :: %__MODULE__{
            external_id: String.t(),
            kind: String.t(),
            display_name: String.t(),
            parent_external_id: String.t() | nil,
            provider_metadata: map()
          }
  end

  @doc """
  Upserts one normalized directory human and optionally syncs group memberships.

  `attrs` is the `Principals.upsert_platform_subject_human/1` attribute map the
  adapter normalized from the provider payload. When `opts` carries
  `:group_external_ids`, memberships are replaced with exactly those external
  groups (an empty list clears them); without the key memberships stay
  untouched, which is what login-path upserts want. `:directory_group_index`
  is forwarded so sync loops can reuse one prefetched index.
  """
  @spec upsert_user(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_user(provider_id, attrs, opts \\ [])
      when is_binary(provider_id) and is_map(attrs) and is_list(opts) do
    with {:ok, observed} <- Principals.upsert_platform_subject_human(attrs),
         {:ok, _sync} <- maybe_sync_memberships(provider_id, observed.principal.uid, opts) do
      {:ok, observed}
    end
  end

  @doc """
  Ensures the Principal group and active external binding for one directory group.

  Creates the group when unseen, refreshes display name and metadata when it
  exists, and upserts the `active` binding either way.
  """
  @spec ensure_group(String.t(), Group.t()) :: {:ok, struct()} | {:error, term()}
  def ensure_group(provider_id, %Group{} = group) when is_binary(provider_id) do
    with {:ok, principal_group} <- fetch_or_create_group(provider_id, group),
         {:ok, principal_group} <-
           AuthZ.update_principal_group(principal_group, %{
             display_name: group.display_name,
             metadata: group_metadata(provider_id, group)
           }),
         :ok <- bind_group(provider_id, group, principal_group.id, "active") do
      {:ok, principal_group}
    end
  end

  @doc """
  Disables one directory group: clears its synced members and marks the binding.
  """
  @spec disable_group(String.t(), Group.t()) ::
          {:ok, %{group_id: term(), removed_memberships: non_neg_integer()}} | {:error, term()}
  def disable_group(provider_id, %Group{} = group) when is_binary(provider_id) do
    with {:ok, principal_group} <- fetch_group(provider_id, group.external_id),
         {:ok, result} <- AuthZ.replace_static_group_members(principal_group.id, :directory, []),
         :ok <- bind_group(provider_id, group, principal_group.id, "disabled") do
      {:ok, %{group_id: principal_group.id, removed_memberships: result.removed_memberships}}
    end
  end

  @doc """
  Fetches the Principal group bound to one provider directory group.
  """
  @spec fetch_group(String.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  def fetch_group(provider_id, external_id) when is_binary(external_id) do
    case AuthZ.external_group_ids(provider_id, :directory_department, external_id) do
      [group_id | _rest] -> AuthZ.get_principal_group(group_id)
      [] -> {:error, :not_found}
    end
  end

  def fetch_group(_provider_id, _external_id), do: {:error, :not_found}

  @doc """
  Replaces one group's synced members from provider member external ids.

  Members the provider named but this installation has never imported are
  skipped and logged, not errors: directory sync may see a group before its
  users, and the next full sync converges them.
  """
  @spec replace_group_members(String.t(), term(), [String.t()]) ::
          {:ok,
           %{removed_memberships: non_neg_integer(), skipped_unknown_members: non_neg_integer()}}
          | {:error, term()}
  def replace_group_members(provider_id, principal_group_id, member_external_ids) do
    with {:ok, uids, skipped} <- resolve_known_members(provider_id, member_external_ids),
         {:ok, result} <-
           AuthZ.replace_static_group_members(principal_group_id, :directory, uids) do
      maybe_log_skipped_members(provider_id, principal_group_id, skipped)

      {:ok, %{removed_memberships: result.removed_memberships, skipped_unknown_members: skipped}}
    end
  end

  @doc """
  Resolves provider member external ids to Principal uids, counting unknowns.
  """
  @spec resolve_known_members(String.t(), [String.t()]) ::
          {:ok, [String.t()], non_neg_integer()} | {:error, term()}
  def resolve_known_members(provider_id, external_ids) do
    external_ids
    |> Enum.reduce_while({:ok, [], 0}, fn external_id, {:ok, uids, skipped} ->
      case Principals.resolve_platform_subject_uid(provider_id, external_id) do
        {:ok, uid} -> {:cont, {:ok, [uid | uids], skipped}}
        {:error, :not_found} -> {:cont, {:ok, uids, skipped + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, uids, skipped} -> {:ok, Enum.reverse(uids), skipped}
      {:error, _reason} = error -> error
    end
  end

  defp maybe_sync_memberships(provider_id, principal_uid, opts) do
    case Keyword.fetch(opts, :group_external_ids) do
      {:ok, ids} when is_list(ids) ->
        AuthZ.sync_external_directory_group_memberships(
          provider_id,
          principal_uid,
          ids,
          Keyword.take(opts, [:directory_group_index])
        )

      :error ->
        {:ok, :memberships_untouched}
    end
  end

  defp fetch_or_create_group(provider_id, group) do
    case fetch_group(provider_id, group.external_id) do
      {:ok, principal_group} -> {:ok, principal_group}
      {:error, :not_found} -> fetch_or_create_by_name(provider_id, group)
      {:error, _reason} = error -> error
    end
  end

  defp fetch_or_create_by_name(provider_id, group) do
    attrs = %{
      name: group_name(provider_id, group),
      display_name: group.display_name,
      domain: :directory,
      metadata: group_metadata(provider_id, group)
    }

    case AuthZ.get_principal_group(attrs.name) do
      {:ok, principal_group} -> {:ok, principal_group}
      {:error, :not_found} -> AuthZ.create_principal_group(attrs)
    end
  end

  defp bind_group(provider_id, group, principal_group_id, status) do
    case AuthZ.upsert_external_binding(%{
           provider: provider_id,
           external_kind: :directory_department,
           external_id: group.external_id,
           group_id: principal_group_id,
           metadata:
             MapHelpers.compact_metadata_map(%{
               "provider" => provider_id,
               "externalID" => group.external_id,
               "name" => group.display_name,
               "parentExternalID" => group.parent_external_id,
               "status" => status,
               "syncedAt" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
               "external_directory" => external_directory_metadata(provider_id, group)
             })
         }) do
      {:ok, _binding} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp group_name(provider_id, group) do
    "#{provider_id}:#{group.kind}:#{String.downcase(group.external_id)}"
  end

  defp group_metadata(provider_id, group) do
    Map.merge(
      %{"external_directory" => external_directory_metadata(provider_id, group)},
      group.provider_metadata
    )
  end

  defp external_directory_metadata(provider_id, group) do
    MapHelpers.compact_metadata_map(%{
      "provider" => provider_id,
      "kind" => group.kind,
      "external_id" => group.external_id,
      "parentExternalID" => group.parent_external_id
    })
  end

  defp maybe_log_skipped_members(_provider_id, _group_id, 0), do: :ok

  defp maybe_log_skipped_members(provider_id, group_id, count) do
    Logging.warning(
      "identity_providers.directory.unknown_group_members",
      "directory group sync skipped unknown members",
      %{provider_id: provider_id, group_id: group_id, count: count}
    )
  end
end
