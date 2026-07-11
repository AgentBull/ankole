defmodule Ankole.Plugins.SlackAdapter.IdentityProvider do
  @moduledoc false

  alias Ankole.{AuthZ, Logging, Principals}
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Plugins.SlackAdapter.{Config, MapHelpers}
  alias SlackOpenAPI.{Event, OIDC, Pagination}

  @spec identity_consumer(String.t(), map()) :: map()
  def identity_consumer(provider_id, config),
    do: %{kind: :identity_provider, provider_id: provider_id, config: config}

  @spec authorization_url(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(config, opts) do
    with true <- get_in(config, ["oidc", "enabled"]) != false || {:error, :oidc_disabled},
         {:ok, redirect_uri} <- required_opt(opts, :redirect_uri),
         {:ok, state} <- required_opt(opts, :state) do
      {:ok,
       OIDC.authorize_url(
         client_id: Map.fetch!(config, "clientID"),
         redirect_uri: redirect_uri,
         state: state,
         scopes: get_in(config, ["oidc", "scopes"]) || ["openid", "profile", "email"],
         team: Map.get(config, "teamID")
       )}
    end
  end

  @spec exchange_code(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange_code(config, code, opts \\ []) do
    base_url = Map.get(config, "baseURL") || "https://slack.com/api"

    with {:ok, token} <-
           OIDC.exchange_code(nil,
             client_id: Map.fetch!(config, "clientID"),
             client_secret: Map.fetch!(config, "clientSecret"),
             code: code,
             redirect_uri: Keyword.get(opts, :redirect_uri),
             base_url: base_url
           ),
         {:ok, claims} <- OIDC.user_info(token.access_token, base_url: base_url),
         user <- normalize_claims(claims),
         {:ok, user} <- hydrate_user(config, user, opts) do
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
               display_name: display_name(user),
               avatar_url: avatar_url(user),
               email: profile_value(user, "email") || MapHelpers.optional_text(user, "email"),
               job_title: profile_value(user, "title"),
               mobile: normalized_mobile(user),
               metadata:
                 MapHelpers.compact_metadata_map(%{
                   "team_id" => MapHelpers.optional_text(user, "team_id"),
                   "is_bot" => Map.get(user, "is_bot"),
                   "deleted" => Map.get(user, "deleted"),
                   "tz" => MapHelpers.optional_text(user, "tz")
                 })
             }
             |> MapHelpers.compact_map()
           ),
         {:ok, _sync} <- maybe_sync_usergroups(provider_id, observed.principal.uid, opts) do
      {:ok, observed}
    end
  end

  @spec sync_directory(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_directory(provider_id, config, opts \\ []) do
    with {:ok, %{usergroups: group_count, user_index: user_index}} <-
           sync_usergroups(provider_id, config, opts),
         {:ok, user_count} <- sync_users(provider_id, config, user_index, opts) do
      {:ok, %{users: user_count, usergroups: group_count}}
    end
  end

  @spec handle_contact_event(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_contact_event(event_type, %Event{} = event, consumers) do
    consumers
    |> Enum.filter(&match?(%{kind: :identity_provider}, &1))
    |> Enum.map(&handle_event(&1, event_type, event))
    |> MapHelpers.collect_results()
  end

  defp sync_usergroups(provider_id, config, opts) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))

    with {:ok, %{"usergroups" => groups}} <-
           SlackOpenAPI.get(client, "usergroups.list",
             query: [include_users: true, include_disabled: false]
           ) do
      Enum.reduce_while(groups, {:ok, %{usergroups: 0, user_index: %{}}}, fn group, {:ok, acc} ->
        with {:ok, group_id} <- usergroup_id(group),
             {:ok, _directory_group} <- ensure_usergroup_group(provider_id, group),
             {:ok, members} <- complete_group_members(client, group) do
          index =
            Enum.reduce(
              members,
              acc.user_index,
              &Map.update(&2, &1, [group_id], fn ids -> [group_id | ids] end)
            )

          {:cont, {:ok, %{usergroups: acc.usergroups + 1, user_index: index}}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp sync_users(provider_id, config, user_index, opts) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))
    page_size = get_in(config, ["sync", "pageSize"]) || 200

    with {:ok, directory_group_index} <- AuthZ.external_directory_group_index(provider_id) do
      Pagination.stream(client, "users.list", query: [limit: page_size], items: ["members"])
      |> Enum.reduce_while({:ok, 0}, fn
        {:ok, user}, {:ok, count} ->
          if directory_human?(user) do
            user_id = Map.get(user, "id")

            case upsert_user(provider_id, user,
                   directory_group_index: directory_group_index,
                   usergroup_ids: Map.get(user_index, user_id, [])
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

  defp handle_event(consumer, event_type, event)
       when event_type in ["team_join", "user_change"] do
    user = get_in(event.content || %{}, ["user"]) || %{}

    cond do
      not directory_human?(user) ->
        {:ok, %{status: :ignored_directory_subject}}

      is_binary(Map.get(user, "id")) ->
        upsert_user(consumer.provider_id, user)

      true ->
        Logging.warning(
          "slack_adapter.identity_provider.missing_user_id",
          "Slack directory event ignored without user id",
          %{event_id: event.id, event_type: event_type}
        )

        {:ok, %{status: :ignored_missing_user_id}}
    end
  end

  defp handle_event(consumer, "subteam_created", event) do
    group = get_in(event.content || %{}, ["subteam"]) || %{}

    case ensure_usergroup_group(consumer.provider_id, group) do
      {:ok, directory_group} -> {:ok, %{status: :usergroup_created, group_id: directory_group.id}}
      {:error, _reason} = error -> error
    end
  end

  defp handle_event(consumer, "subteam_updated", event) do
    group = get_in(event.content || %{}, ["subteam"]) || %{}

    with {:ok, external_id} <- usergroup_id(group),
         {:ok, directory_group} <- existing_usergroup(consumer.provider_id, external_id) do
      if disabled_usergroup?(group) do
        with {:ok, result} <-
               AuthZ.replace_static_group_members(directory_group.id, :directory, []),
             :ok <-
               upsert_group_binding(
                 consumer.provider_id,
                 external_id,
                 group,
                 directory_group.id,
                 "disabled"
               ) do
          {:ok, %{status: :usergroup_disabled, removed_memberships: result.removed_memberships}}
        end
      else
        with {:ok, directory_group} <-
               AuthZ.update_principal_group(directory_group, %{
                 display_name: usergroup_display_name(group, external_id),
                 metadata: group_metadata(consumer.provider_id, external_id, group)
               }),
             {:ok, members} <- complete_group_members(Config.client(consumer.config), group),
             {:ok, uids, skipped} <- resolve_known_members(consumer.provider_id, members),
             {:ok, result} <-
               AuthZ.replace_static_group_members(directory_group.id, :directory, uids),
             :ok <-
               upsert_group_binding(
                 consumer.provider_id,
                 external_id,
                 group,
                 directory_group.id,
                 "active"
               ) do
          maybe_log_skipped_members(external_id, skipped)

          {:ok,
           %{
             status: :usergroup_updated,
             removed_memberships: result.removed_memberships,
             skipped_unknown_users: skipped
           }}
        end
      end
    else
      {:error, :not_found} -> {:ok, %{status: :ignored_unknown_usergroup}}
      {:error, _reason} = error -> error
    end
  end

  defp handle_event(consumer, "subteam_members_changed", event) do
    content = event.content || %{}
    external_id = Map.get(content, "subteam_id")

    with {:ok, directory_group} <- existing_usergroup(consumer.provider_id, external_id) do
      added = MapHelpers.fetch_list(content, "added_users")
      removed = MapHelpers.fetch_list(content, "removed_users")

      if truncated_delta?(content, added, removed) do
        with {:ok, %{"users" => users}} <-
               SlackOpenAPI.get(Config.client(consumer.config), "usergroups.users.list",
                 query: [usergroup: external_id]
               ),
             {:ok, uids, skipped} <- resolve_known_members(consumer.provider_id, users),
             {:ok, result} <-
               AuthZ.replace_static_group_members(directory_group.id, :directory, uids) do
          maybe_log_skipped_members(external_id, skipped)

          {:ok,
           %{status: :usergroup_members_replaced, removed_memberships: result.removed_memberships}}
        end
      else
        apply_member_delta(consumer.provider_id, directory_group.id, added, removed)
      end
    else
      {:error, :not_found} -> {:ok, %{status: :ignored_unknown_usergroup}}
      {:error, _reason} = error -> error
    end
  end

  defp handle_event(_consumer, _event_type, _event),
    do: {:ok, %{status: :ignored_unknown_contact_event}}

  defp ensure_usergroup_group(provider_id, group) do
    with {:ok, external_id} <- usergroup_id(group) do
      result =
        case AuthZ.external_group_ids(provider_id, :directory_department, external_id) do
          [group_id | _rest] -> AuthZ.get_principal_group(group_id)
          [] -> fetch_or_create_group(provider_id, external_id, group)
        end

      with {:ok, directory_group} <- result,
           {:ok, directory_group} <-
             AuthZ.update_principal_group(directory_group, %{
               display_name: usergroup_display_name(group, external_id),
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
      name: "#{provider_id}:usergroup:#{String.downcase(external_id)}",
      display_name: usergroup_display_name(group, external_id),
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
               "name" => usergroup_display_name(group, external_id),
               "status" => status,
               "syncedAt" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601(),
               "external_directory" => %{
                 "provider" => provider_id,
                 "kind" => "usergroup",
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
        "kind" => "usergroup",
        "external_id" => external_id
      },
      "slack" =>
        MapHelpers.compact_metadata_map(%{
          "handle" => MapHelpers.optional_text(group, "handle"),
          "name" => MapHelpers.optional_text(group, "name"),
          "user_count" => user_count(group),
          "date_delete" => Map.get(group, "date_delete")
        })
    }
  end

  defp complete_group_members(client, group) do
    users = MapHelpers.fetch_list(group, "users")

    if user_count(group) > length(users) do
      case SlackOpenAPI.get(client, "usergroups.users.list", query: [usergroup: group["id"]]) do
        {:ok, %{"users" => complete}} -> {:ok, complete}
        {:ok, body} -> {:error, {:unexpected_usergroup_members, body}}
        {:error, _reason} = error -> error
      end
    else
      {:ok, users}
    end
  end

  defp maybe_sync_usergroups(provider_id, principal_uid, opts) do
    case Keyword.fetch(opts, :usergroup_ids) do
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

  defp apply_member_delta(provider_id, group_id, added, removed) do
    with {:ok, added_uids, skipped_added} <- resolve_known_members(provider_id, added),
         {:ok, removed_uids, skipped_removed} <- resolve_known_members(provider_id, removed),
         :ok <- add_members(group_id, added_uids),
         :ok <- remove_members(group_id, removed_uids) do
      skipped = skipped_added + skipped_removed

      {:ok,
       %{
         status: :usergroup_members_delta_applied,
         added: length(added_uids),
         removed: length(removed_uids),
         skipped_unknown_users: skipped
       }}
    end
  end

  defp add_members(group_id, uids) do
    Enum.reduce_while(uids, :ok, fn uid, :ok ->
      case AuthZ.add_principal_to_group(uid, group_id) do
        {:ok, _membership} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp remove_members(group_id, uids) do
    Enum.reduce_while(uids, :ok, fn uid, :ok ->
      case AuthZ.remove_principal_from_group(uid, group_id) do
        {:ok, :deleted} -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
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

  defp existing_usergroup(provider_id, external_id) when is_binary(external_id) do
    case AuthZ.external_group_ids(provider_id, :directory_department, external_id) do
      [group_id | _rest] -> AuthZ.get_principal_group(group_id)
      [] -> {:error, :not_found}
    end
  end

  defp existing_usergroup(_provider_id, _external_id), do: {:error, :not_found}

  defp hydrate_user(config, user, opts) do
    if is_binary(Map.get(config, "botToken")) do
      case SlackOpenAPI.get(
             Config.client(config, Keyword.get(opts, :client_opts, [])),
             "users.info",
             query: [user: user["user_id"]]
           ) do
        {:ok, %{"user" => hydrated}} ->
          {:ok, Map.merge(user, hydrated)}

        {:ok, _body} ->
          {:ok, user}

        {:error, reason} ->
          Logging.warning(
            "slack_adapter.identity_provider.user_hydration_failed",
            "Slack user hydration failed",
            %{reason: inspect(reason)}
          )

          {:ok, user}
      end
    else
      {:ok, user}
    end
  end

  defp normalize_claims(claims) do
    %{
      "user_id" => claims["https://slack.com/user_id"] || claims["sub"],
      "team_id" => claims["https://slack.com/team_id"],
      "email" => claims["email"],
      "name" => claims["name"],
      "picture" => claims["picture"],
      "locale" => claims["locale"]
    }
    |> MapHelpers.compact_map()
  end

  defp directory_human?(user) do
    is_binary(Map.get(user, "id")) and Map.get(user, "id") != "USLACKBOT" and
      Map.get(user, "is_bot") != true and Map.get(user, "deleted") != true
  end

  defp user_id(user) do
    case MapHelpers.optional_text(user, "user_id") || MapHelpers.optional_text(user, "id") do
      nil -> {:error, :missing_user_id}
      id -> {:ok, id}
    end
  end

  defp usergroup_id(group) do
    case MapHelpers.optional_text(group, "id") do
      nil -> {:error, :missing_usergroup_id}
      id -> {:ok, id}
    end
  end

  defp display_name(user) do
    profile_value(user, "display_name") || MapHelpers.optional_text(user, "real_name") ||
      MapHelpers.optional_text(user, "name") || MapHelpers.optional_text(user, "user_id") ||
      MapHelpers.optional_text(user, "id")
  end

  defp avatar_url(user) do
    profile_value(user, "image_512") || MapHelpers.optional_text(user, "picture")
  end

  defp profile_value(user, key),
    do: user |> MapHelpers.fetch_map("profile", %{}) |> MapHelpers.optional_text(key)

  defp normalized_mobile(user) do
    case profile_value(user, "phone") do
      nil ->
        nil

      phone ->
        candidates = [
          String.trim(phone),
          phone |> String.replace(~r/\D/, "") |> maybe_china_number()
        ]

        Enum.find_value(candidates, fn
          nil ->
            nil

          candidate ->
            case NativeKernel.phone_normalize_e164(candidate) do
              normalized when is_binary(normalized) -> normalized
              {:error, _reason} -> nil
            end
        end)
    end
  end

  defp maybe_china_number(<<"1", _::binary-size(10)>> = digits), do: "+86" <> digits
  defp maybe_china_number(_digits), do: nil

  defp usergroup_display_name(group, external_id) do
    MapHelpers.optional_text(group, "name") || MapHelpers.optional_text(group, "handle") ||
      "Slack User Group #{external_id}"
  end

  defp user_count(group) do
    case Map.get(group, "user_count") do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {count, _rest} -> count
          :error -> length(MapHelpers.fetch_list(group, "users"))
        end

      _value ->
        length(MapHelpers.fetch_list(group, "users"))
    end
  end

  defp disabled_usergroup?(group),
    do: is_integer(Map.get(group, "date_delete")) and Map.get(group, "date_delete") > 0

  defp truncated_delta?(content, added, removed) do
    count_mismatch?(Map.get(content, "added_users_count"), added) or
      count_mismatch?(Map.get(content, "removed_users_count"), removed)
  end

  defp count_mismatch?(count, values) when is_integer(count), do: count != length(values)
  defp count_mismatch?(_count, _values), do: false

  defp maybe_log_skipped_members(_external_id, 0), do: :ok

  defp maybe_log_skipped_members(external_id, count),
    do:
      Logging.warning(
        "slack_adapter.identity_provider.unknown_usergroup_members",
        "Slack usergroup skipped unknown users",
        %{external_id: external_id, count: count}
      )

  defp required_opt(opts, key) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end
end
