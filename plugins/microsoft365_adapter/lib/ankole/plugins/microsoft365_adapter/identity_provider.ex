defmodule Ankole.Plugins.Microsoft365Adapter.IdentityProvider do
  @moduledoc false

  alias Ankole.{AuthZ, Logging, Principals}
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Plugins.Microsoft365Adapter.{Config, MapHelpers}
  alias MicrosoftOpenAPI.EntraAuth
  alias MicrosoftOpenAPI.Error
  alias MicrosoftOpenAPI.Graph
  alias MicrosoftOpenAPI.Pagination

  @me_select "id,displayName,mail,userPrincipalName,jobTitle,mobilePhone,department,accountEnabled"
  @user_select "id,displayName,mail,userPrincipalName,jobTitle,mobilePhone,department,accountEnabled,userType"
  @group_select "id,displayName,description,securityEnabled,groupTypes,mailNickname"

  @spec identity_consumer(String.t(), map()) :: map()
  def identity_consumer(provider_id, config),
    do: %{kind: :identity_provider, provider_id: provider_id, config: config}

  @spec authorization_url(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(config, opts) do
    with true <- get_in(config, ["oidc", "enabled"]) != false || {:error, :oidc_disabled},
         {:ok, redirect_uri} <- required_opt(opts, :redirect_uri),
         {:ok, state} <- required_opt(opts, :state) do
      {:ok,
       EntraAuth.authorize_url(
         login_base_url: Map.get(config, "loginBaseURL") || "https://login.microsoftonline.com",
         tenant: Map.fetch!(config, "tenantID"),
         client_id: Map.fetch!(config, "clientID"),
         redirect_uri: redirect_uri,
         state: state,
         scopes: get_in(config, ["oidc", "scopes"]) || ["openid", "profile", "email", "User.Read"]
       )}
    end
  end

  @spec exchange_code(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange_code(config, code, opts \\ []) do
    client = Config.identity_client(config, Keyword.get(opts, :client_opts, []))

    with {:ok, token} <-
           EntraAuth.exchange_code(client,
             code: code,
             redirect_uri: Keyword.get(opts, :redirect_uri)
           ),
         {:ok, user} <-
           Graph.get(client, "me",
             query: [{"$select", @me_select}],
             token: {:bearer, token.access_token}
           ) do
      {:ok, %{token: token, user: user}}
    end
  end

  @spec upsert_user(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_user(provider_id, user, opts \\ []) do
    with {:ok, user_id} <- user_id(user),
         {:ok, observed} <-
           Principals.upsert_platform_subject_human(
             %{
               provider: provider_id,
               external_id: user_id,
               uid: user_id,
               display_name: MapHelpers.optional_text(user, "displayName") || user_id,
               email:
                 MapHelpers.optional_text(user, "mail") ||
                   MapHelpers.optional_text(user, "userPrincipalName"),
               job_title: MapHelpers.optional_text(user, "jobTitle"),
               mobile: normalized_mobile(user),
               metadata:
                 MapHelpers.compact_metadata_map(%{
                   "user_principal_name" => MapHelpers.optional_text(user, "userPrincipalName"),
                   "department" => MapHelpers.optional_text(user, "department"),
                   "user_type" => MapHelpers.optional_text(user, "userType"),
                   "account_enabled" => Map.get(user, "accountEnabled")
                 })
             }
             |> MapHelpers.compact_map()
           ),
         {:ok, _sync} <- maybe_sync_groups(provider_id, observed.principal.uid, opts) do
      {:ok, observed}
    end
  end

  @spec sync_directory(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_directory(provider_id, config, opts \\ []) do
    with {:ok, %{groups: group_count, user_index: user_index}} <-
           sync_groups(provider_id, config, opts),
         {:ok, user_count} <- sync_users(provider_id, config, user_index, opts) do
      {:ok, %{users: user_count, groups: group_count}}
    end
  end

  @doc """
  Applies one normalized directory change event.

  Events come from the Graph change-notification webhook as
  `%{"resource_kind" => "user" | "group", "change_type" => ..., "id" => ...}`.
  Basic notifications carry only ids, so updates re-fetch the authoritative
  object before writing.
  """
  @spec handle_contact_event(String.t(), map(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_contact_event(event_type, event, consumers) when is_map(event) do
    consumers
    |> Enum.filter(&match?(%{kind: :identity_provider}, &1))
    |> Enum.map(&handle_event(&1, event_type, event))
    |> MapHelpers.collect_results()
  end

  defp handle_event(consumer, "user.updated", %{"id" => user_id}) when is_binary(user_id) do
    client = Config.identity_client(consumer.config, consumer_client_opts(consumer))

    case Graph.get(client, "users/" <> encode_segment(user_id),
           query: [{"$select", @user_select}]
         ) do
      {:ok, user} ->
        if directory_user?(user, consumer.config) do
          upsert_user(consumer.provider_id, user)
        else
          {:ok, %{status: :ignored_directory_subject}}
        end

      {:error, %Error{status: 404}} ->
        {:ok, %{status: :ignored_missing_user}}

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_event(_consumer, "user.deleted", _event) do
    # Deletion converges through group.updated notifications and periodic full
    # sync, mirroring the Slack adapter's treatment of deleted users.
    {:ok, %{status: :ignored_deleted_user}}
  end

  defp handle_event(consumer, "group.updated", %{"id" => group_id}) when is_binary(group_id) do
    client = Config.identity_client(consumer.config, consumer_client_opts(consumer))

    case Graph.get(client, "groups/" <> encode_segment(group_id),
           query: [{"$select", @group_select}]
         ) do
      {:ok, group} ->
        with {:ok, directory_group} <- ensure_entra_group(consumer.provider_id, group),
             {:ok, member_ids} <- group_member_ids(client, group_id, consumer.config),
             {:ok, uids, skipped} <- resolve_known_members(consumer.provider_id, member_ids),
             {:ok, result} <-
               AuthZ.replace_static_group_members(directory_group.id, :directory, uids) do
          maybe_log_skipped_members(group_id, skipped)

          {:ok,
           %{
             status: :group_updated,
             group_id: directory_group.id,
             removed_memberships: result.removed_memberships,
             skipped_unknown_users: skipped
           }}
        end

      {:error, %Error{status: 404}} ->
        disable_group(consumer.provider_id, group_id)

      {:error, _reason} = error ->
        error
    end
  end

  defp handle_event(consumer, "group.deleted", %{"id" => group_id}) when is_binary(group_id),
    do: disable_group(consumer.provider_id, group_id)

  defp handle_event(_consumer, _event_type, _event),
    do: {:ok, %{status: :ignored_unknown_contact_event}}

  defp sync_groups(provider_id, config, opts) do
    client = Config.identity_client(config, Keyword.get(opts, :client_opts, []))
    query = groups_query(config)

    Pagination.stream(client, "groups", query: query)
    |> Enum.reduce_while({:ok, %{groups: 0, user_index: %{}}}, fn
      {:ok, group}, {:ok, acc} ->
        with {:ok, group_id} <- group_id(group),
             {:ok, _directory_group} <- ensure_entra_group(provider_id, group),
             {:ok, member_ids} <- group_member_ids(client, group_id, config) do
          index =
            Enum.reduce(
              member_ids,
              acc.user_index,
              &Map.update(&2, &1, [group_id], fn ids -> [group_id | ids] end)
            )

          {:cont, {:ok, %{groups: acc.groups + 1, user_index: index}}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

  defp sync_users(provider_id, config, user_index, opts) do
    client = Config.identity_client(config, Keyword.get(opts, :client_opts, []))
    page_size = get_in(config, ["sync", "pageSize"]) || 999

    with {:ok, directory_group_index} <- AuthZ.external_directory_group_index(provider_id) do
      Pagination.stream(client, "users",
        query: [{"$select", @user_select}, {"$top", page_size}]
      )
      |> Enum.reduce_while({:ok, 0}, fn
        {:ok, user}, {:ok, count} ->
          if directory_user?(user, config) do
            user_id = Map.get(user, "id")

            case upsert_user(provider_id, user,
                   directory_group_index: directory_group_index,
                   group_ids: Map.get(user_index, user_id, [])
                 ) do
              {:ok, _observed} -> {:cont, {:ok, count + 1}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:cont, {:ok, count}}
          end

        {:error, reason}, _acc ->
          {:halt, {:error, reason}}
      end)
    end
  end

  defp groups_query(config) do
    case get_in(config, ["sync", "groupsFilter"]) do
      filter when is_binary(filter) and filter != "" ->
        [{"$select", @group_select}, {"$filter", filter}]

      _no_filter ->
        [{"$select", @group_select}]
    end
  end

  defp group_member_ids(client, group_id, config) do
    page_size = get_in(config, ["sync", "pageSize"]) || 999

    Pagination.stream(client, "groups/" <> encode_segment(group_id) <> "/members",
      query: [{"$select", "id"}, {"$top", page_size}]
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, member}, {:ok, acc} ->
        if Map.get(member, "@odata.type") == "#microsoft.graph.user" do
          case MapHelpers.optional_text(member, "id") do
            nil -> {:cont, {:ok, acc}}
            id -> {:cont, {:ok, [id | acc]}}
          end
        else
          {:cont, {:ok, acc}}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      error -> error
    end
  end

  defp ensure_entra_group(provider_id, group) do
    with {:ok, external_id} <- group_id(group) do
      result =
        case AuthZ.external_group_ids(provider_id, :directory_department, external_id) do
          [group_id | _rest] -> AuthZ.get_principal_group(group_id)
          [] -> fetch_or_create_group(provider_id, external_id, group)
        end

      with {:ok, directory_group} <- result,
           {:ok, directory_group} <-
             AuthZ.update_principal_group(directory_group, %{
               display_name: group_display_name(group, external_id),
               metadata: group_metadata(provider_id, external_id, group)
             }),
           :ok <-
             upsert_group_binding(provider_id, external_id, group, directory_group.id, "active") do
        {:ok, directory_group}
      end
    end
  end

  defp fetch_or_create_group(provider_id, external_id, group) do
    attrs = %{
      name: "#{provider_id}:entra_group:#{String.downcase(external_id)}",
      display_name: group_display_name(group, external_id),
      domain: :directory,
      metadata: group_metadata(provider_id, external_id, group)
    }

    case AuthZ.get_principal_group(attrs.name) do
      {:ok, directory_group} -> {:ok, directory_group}
      {:error, :not_found} -> AuthZ.create_principal_group(attrs)
    end
  end

  defp upsert_group_binding(provider_id, external_id, group, group_id, status) do
    case AuthZ.upsert_external_binding(%{
           provider: provider_id,
           external_kind: :directory_department,
           external_id: external_id,
           group_id: group_id,
           metadata:
             MapHelpers.compact_metadata_map(%{
               "provider" => provider_id,
               "externalID" => external_id,
               "name" => group_display_name(group, external_id),
               "status" => status,
               "syncedAt" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
               "external_directory" => %{
                 "provider" => provider_id,
                 "kind" => "entra_group",
                 "external_id" => external_id
               }
             })
         }) do
      {:ok, _binding} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp group_metadata(provider_id, external_id, group) do
    %{
      "external_directory" => %{
        "provider" => provider_id,
        "kind" => "entra_group",
        "external_id" => external_id
      },
      "entra" =>
        MapHelpers.compact_metadata_map(%{
          "display_name" => MapHelpers.optional_text(group, "displayName"),
          "mail_nickname" => MapHelpers.optional_text(group, "mailNickname"),
          "security_enabled" => Map.get(group, "securityEnabled"),
          "group_types" => MapHelpers.fetch_list(group, "groupTypes")
        })
    }
  end

  defp disable_group(provider_id, external_id) do
    case existing_group(provider_id, external_id) do
      {:ok, directory_group} ->
        with {:ok, result} <-
               AuthZ.replace_static_group_members(directory_group.id, :directory, []),
             :ok <-
               upsert_group_binding(
                 provider_id,
                 external_id,
                 %{},
                 directory_group.id,
                 "disabled"
               ) do
          {:ok, %{status: :group_disabled, removed_memberships: result.removed_memberships}}
        end

      {:error, :not_found} ->
        {:ok, %{status: :ignored_unknown_group}}

      {:error, _reason} = error ->
        error
    end
  end

  defp existing_group(provider_id, external_id) when is_binary(external_id) do
    case AuthZ.external_group_ids(provider_id, :directory_department, external_id) do
      [group_id | _rest] -> AuthZ.get_principal_group(group_id)
      [] -> {:error, :not_found}
    end
  end

  defp maybe_sync_groups(provider_id, principal_uid, opts) do
    case Keyword.fetch(opts, :group_ids) do
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

  defp resolve_known_members(provider_id, ids) do
    Enum.reduce_while(ids, {:ok, [], 0}, fn id, {:ok, uids, skipped} ->
      case Principals.resolve_platform_subject_uid(provider_id, id) do
        {:ok, uid} -> {:cont, {:ok, [uid | uids], skipped}}
        {:error, :not_found} -> {:cont, {:ok, uids, skipped + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, uids, skipped} -> {:ok, Enum.reverse(uids), skipped}
      error -> error
    end
  end

  @doc false
  @spec directory_user?(map(), map()) :: boolean()
  def directory_user?(user, config) do
    include_guests? = get_in(config, ["sync", "includeGuests"]) == true

    is_binary(Map.get(user, "id")) and Map.get(user, "accountEnabled") != false and
      (include_guests? or MapHelpers.optional_text(user, "userType") != "Guest")
  end

  @doc false
  @spec normalize_claims(map()) :: map()
  def normalize_claims(user) do
    # `me.id` is the directory object id — the stable cross-app identity the
    # chat adapter also uses (aadObjectId). The pairwise OIDC `sub` is never
    # used as an external id.
    %{
      "id" => MapHelpers.optional_text(user, "id"),
      "displayName" => MapHelpers.optional_text(user, "displayName"),
      "mail" => MapHelpers.optional_text(user, "mail"),
      "userPrincipalName" => MapHelpers.optional_text(user, "userPrincipalName"),
      "jobTitle" => MapHelpers.optional_text(user, "jobTitle"),
      "mobilePhone" => MapHelpers.optional_text(user, "mobilePhone"),
      "department" => MapHelpers.optional_text(user, "department")
    }
    |> MapHelpers.compact_map()
  end

  defp consumer_client_opts(consumer), do: Map.get(consumer, :client_opts, [])

  defp user_id(user) do
    case MapHelpers.optional_text(user, "id") do
      nil -> {:error, :missing_user_id}
      id -> {:ok, id}
    end
  end

  defp group_id(group) do
    case MapHelpers.optional_text(group, "id") do
      nil -> {:error, :missing_group_id}
      id -> {:ok, id}
    end
  end

  defp group_display_name(group, external_id) do
    MapHelpers.optional_text(group, "displayName") ||
      MapHelpers.optional_text(group, "mailNickname") || "Entra Group #{external_id}"
  end

  defp normalized_mobile(user) do
    case MapHelpers.optional_text(user, "mobilePhone") do
      nil ->
        nil

      phone ->
        case NativeKernel.phone_normalize_e164(String.trim(phone)) do
          normalized when is_binary(normalized) -> normalized
          {:error, _reason} -> nil
        end
    end
  end

  defp maybe_log_skipped_members(_external_id, 0), do: :ok

  defp maybe_log_skipped_members(external_id, count),
    do:
      Logging.warning(
        "microsoft365_adapter.identity_provider.unknown_group_members",
        "Entra group sync skipped unknown users",
        %{external_id: external_id, count: count}
      )

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)

  defp required_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end
end
