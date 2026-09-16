defmodule Ankole.Plugins.LarkAdapter.IdentityProvider do
  @moduledoc """
  Lark / Feishu identity-provider adapter functions for Principals.
  """

  alias Ankole.AuthZ
  alias Ankole.IdentityProviders.Directory
  alias Ankole.IdentityProviders.DirectoryAccess
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.SubjectIdentity
  alias Ankole.Plugins.MapHelpers
  alias FeishuOpenAPI.Auth
  alias FeishuOpenAPI.Event
  alias FeishuOpenAPI.Pagination

  import MapHelpers,
    only: [
      collect_results: 1,
      compact_metadata_map: 1,
      fetch_list: 2,
      fetch_map: 3,
      optional_text: 2
    ]

  @doc """
  Builds the dispatcher consumer record for one configured identity provider.
  """
  @spec identity_consumer(String.t(), map()) :: map()
  def identity_consumer(provider_id, config) when is_binary(provider_id) and is_map(config) do
    %{kind: :identity_provider, provider_id: provider_id, config: config}
  end

  @doc """
  Builds the provider authorization URL for OIDC login.
  """
  @spec authorization_url(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def authorization_url(config, opts) when is_map(config) and is_list(opts) do
    with {:ok, redirect_uri} <- MapHelpers.required_opt(opts, :redirect_uri),
         {:ok, state} <- MapHelpers.required_opt(opts, :state) do
      query =
        [
          app_id: Map.fetch!(config, "appID"),
          redirect_uri: redirect_uri,
          state: state,
          scope: Enum.join(get_in(config, ["oidc", "scopes"]) || [], " ")
        ]
        |> URI.encode_query()

      {:ok,
       "#{Config.domain_base_url(Map.fetch!(config, "domain"))}/open-apis/authen/v1/authorize?#{query}"}
    end
  end

  @doc """
  Exchanges an OIDC code and hydrates the user with contact data when possible.
  """
  @spec exchange_code(map(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def exchange_code(config, code, opts \\ []) when is_map(config) and is_binary(code) do
    client = Config.client(config)

    with {:ok, token} <-
           Auth.user_access_token(client, code, redirect_uri: Keyword.get(opts, :redirect_uri)),
         {:ok, user_info} <- user_info(client, token.access_token),
         {:ok, hydrated} <- hydrate_contact_user(client, user_info) do
      {:ok, %{token: token, user: hydrated}}
    end
  end

  @doc """
  Merges one Lark contact user into the Principal platform-subject model.
  """
  @spec upsert_user(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def upsert_user(provider_id, user, opts \\ []) when is_binary(provider_id) and is_map(user) do
    email = identity_email(user)

    with [external_id | external_ids] <- subject_candidates(user, email) do
      department_ids = fetch_list(user, "department_ids")

      Directory.upsert_user(
        provider_id,
        %{
          provider: provider_id,
          external_id: external_id,
          external_ids: external_ids,
          display_name: display_name(user),
          avatar_url: avatar_url(user),
          email: email,
          mobile: normalized_mobile(user),
          job_title: optional_text(user, "job_title"),
          metadata:
            compact_metadata_map(%{
              "user_id" => optional_text(user, "user_id") || optional_text(user, "id"),
              "open_id" => optional_text(user, "open_id"),
              "union_id" => optional_text(user, "union_id"),
              "tenant_key" => optional_text(user, "tenant_key"),
              "employee_no" => optional_text(user, "employee_no"),
              "department_ids" => department_ids
            })
        },
        [group_external_ids: department_ids, access_observation: access_observation(user)] ++
          Keyword.take(opts, [:directory_group_index, :observed_at, :operation_id])
      )
    else
      [] -> {:error, :missing_platform_subject}
    end
  end

  @doc """
  Runs a full directory sync and stops on the first write or provider error.
  """
  @spec sync_directory(String.t(), map(), keyword()) ::
          {:ok, %{users: non_neg_integer(), departments: non_neg_integer()}} | {:error, term()}
  def sync_directory(provider_id, config, _opts \\ [])
      when is_binary(provider_id) and is_map(config) do
    with {:ok, ticket} <- DirectoryAccess.begin_sync(provider_id, config) do
      case collect_and_sync(provider_id, config, ticket) do
        {:ok, _} = result -> result
        {:error, reason} -> DirectoryAccess.fail_sync(ticket, reason)
      end
    end
  end

  defp collect_and_sync(provider_id, config, ticket) do
    client = Config.client(config)
    page_size = get_in(config, ["sync", "pageSize"]) || 50
    admission = get_in(config, ["sync", "admissionScope"]) || "none"

    with {:ok, scope} <- directory_scope(client, admission),
         {:ok, expanded_scope} <- expand_group_scope(client, scope, page_size),
         {:ok, departments} <-
           collect_departments(client, expanded_scope["department_ids"], page_size),
         :ok <- sync_departments(provider_id, departments),
         department_ids <-
           Enum.uniq(
             expanded_scope["department_ids"] ++
               Enum.map(departments, &elem(department_id(&1), 1))
           ),
         {:ok, users} <- collect_directory_users(client, department_ids, page_size),
         {:ok, users} <- collect_explicit_users(client, expanded_scope["user_ids"], users),
         {:ok, ^scope} <- directory_scope(client, admission),
         {:ok, directory_group_index} <- AuthZ.external_directory_group_index(provider_id),
         {:ok, observations} <-
           sync_users(provider_id, Map.values(users), directory_group_index, ticket),
         {:ok, _} <-
           DirectoryAccess.finish_sync(
             ticket,
             {config["domain"], config["appID"], scope},
             observations,
             admission_scope: admission,
             maximum_removal_percent: get_in(config, ["sync", "maximumRemovalPercent"]) || 20
           ) do
      {:ok, %{users: map_size(users), departments: length(departments)}}
    else
      {:ok, _changed_scope} -> {:error, :directory_scope_changed}
      error -> error
    end
  end

  defp directory_scope(_client, "none"),
    do: {:ok, %{"department_ids" => ["0"], "user_ids" => [], "group_ids" => []}}

  defp directory_scope(client, "contact"),
    do:
      collect_scope(client, nil, MapSet.new(), %{
        "department_ids" => [],
        "user_ids" => [],
        "group_ids" => []
      })

  defp collect_scope(client, cursor, seen, acc) do
    query = [user_id_type: "user_id", department_id_type: "department_id", page_size: 100]
    query = if cursor, do: Keyword.put(query, :page_token, cursor), else: query

    with {:ok, %{"data" => data}} <- FeishuOpenAPI.get(client, "contact/v3/scopes", query: query),
         true <-
           Enum.all?(~w(user_ids department_ids group_ids), fn key ->
             is_list(data[key]) and Enum.all?(data[key], &(is_binary(&1) and &1 != ""))
           end),
         true <- is_boolean(data["has_more"]) do
      acc = Map.new(acc, fn {key, values} -> {key, Enum.sort(Enum.uniq(values ++ data[key]))} end)
      next = data["page_token"]

      cond do
        data["has_more"] == false ->
          {:ok, acc}

        is_binary(next) and next != "" and not MapSet.member?(seen, next) ->
          collect_scope(client, next, MapSet.put(seen, next), acc)

        true ->
          {:error, :invalid_scope_page}
      end
    else
      false -> {:error, :unverified_directory_scope}
      {:ok, _} -> {:error, :invalid_scope_page}
      error -> error
    end
  end

  defp expand_group_scope(client, scope, page_size) do
    Enum.reduce_while(scope["group_ids"], {:ok, scope}, fn group_id, {:ok, acc} ->
      result =
        Enum.reduce_while(
          [{"user", "user_id", "user_ids"}, {"department", "department_id", "department_ids"}],
          {:ok, acc},
          fn {kind, id_type, key}, {:ok, acc} ->
            with {:ok, members} <-
                   collect_pages(
                     Pagination.stream(client, "contact/v3/group/:group_id/member/simplelist",
                       path_params: %{group_id: group_id},
                       query: [member_type: kind, member_id_type: id_type, page_size: page_size],
                       items: ["data", "memberlist"],
                       strict: true
                     )
                   ),
                 true <-
                   Enum.all?(members, &(is_binary(&1["member_id"]) and &1["member_id"] != "")) do
              {:cont,
               {:ok,
                Map.update!(
                  acc,
                  key,
                  &Enum.uniq(&1 ++ Enum.map(members, fn member -> member["member_id"] end))
                )}}
            else
              false -> {:halt, {:error, :invalid_group_members}}
              error -> {:halt, error}
            end
          end
        )

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  defp collect_departments(client, roots, page_size) do
    Enum.reduce_while(roots, {:ok, %{}}, fn root, {:ok, acc} ->
      with {:ok, root_department} <- fetch_root_department(client, root),
           {:ok, children} <-
             collect_pages(
               Pagination.stream(client, "contact/v3/departments/:department_id/children",
                 path_params: %{department_id: root},
                 query: [
                   department_id_type: "department_id",
                   fetch_child: true,
                   page_size: page_size,
                   user_id_type: "user_id"
                 ],
                 strict: true
               )
             ),
           {:ok, acc} <-
             Enum.reduce_while(root_department ++ children, {:ok, acc}, fn department,
                                                                           {:ok, acc} ->
               case department_id(department) do
                 {:ok, id} -> {:cont, {:ok, Map.put(acc, id, department)}}
                 error -> {:halt, error}
               end
             end) do
        {:cont, {:ok, acc}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, departments} -> {:ok, Map.values(departments)}
      error -> error
    end
  end

  defp fetch_root_department(_client, "0"), do: {:ok, []}

  defp fetch_root_department(client, id) do
    case FeishuOpenAPI.get(client, "contact/v3/departments/:department_id",
           path_params: %{department_id: id},
           query: [department_id_type: "department_id", user_id_type: "user_id"]
         ) do
      {:ok, %{"data" => %{"department" => department}}} when is_map(department) ->
        {:ok, [department]}

      {:ok, _} ->
        {:error, :invalid_department_response}

      error ->
        error
    end
  end

  defp collect_pages(stream) do
    Enum.reduce_while(stream, {:ok, []}, fn
      {:ok, item}, {:ok, acc} -> {:cont, {:ok, [item | acc]}}
      {:error, _} = error, _ -> {:halt, error}
    end)
  end

  defp sync_departments(provider_id, departments) do
    Enum.reduce_while(departments, :ok, fn department, :ok ->
      case ensure_department_group(provider_id, department) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp collect_directory_users(client, department_ids, page_size) do
    Enum.reduce_while(department_ids, {:ok, %{}}, fn id, {:ok, users} ->
      with {:ok, items} <-
             collect_pages(
               Pagination.stream(client, "contact/v3/users",
                 query: [
                   department_id: id,
                   department_id_type: "department_id",
                   page_size: page_size,
                   user_id_type: "user_id"
                 ],
                 strict: true
               )
             ),
           {:ok, users} <- merge_directory_users(users, items) do
        {:cont, {:ok, users}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp collect_explicit_users(client, ids, users) do
    Enum.reduce_while(ids, {:ok, users}, fn id, {:ok, users} ->
      case FeishuOpenAPI.get(client, "contact/v3/users/:user_id",
             path_params: %{user_id: id},
             query: [user_id_type: "user_id"]
           ) do
        {:ok, %{"data" => %{"user" => user}}} when is_map(user) ->
          case merge_directory_users(users, [user]) do
            {:ok, users} -> {:cont, {:ok, users}}
            error -> {:halt, error}
          end

        {:ok, _} ->
          {:halt, {:error, :invalid_user_response}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp merge_directory_users(users, items) do
    Enum.reduce_while(items, {:ok, users}, fn user, {:ok, acc} ->
      case directory_user_key(user) do
        {:ok, key} -> {:cont, {:ok, Map.update(acc, key, user, &merge_user(&1, user))}}
        error -> {:halt, error}
      end
    end)
  end

  defp sync_users(provider_id, users, directory_group_index, ticket) do
    Enum.reduce_while(users, {:ok, []}, fn user, {:ok, observations} ->
      case upsert_user(provider_id, user,
             directory_group_index: directory_group_index,
             observed_at: ticket.last_started_at,
             operation_id: "snapshot:" <> ticket.id <> ":" <> to_string(ticket.revision)
           ) do
        {:ok, observed} ->
          {:cont, {:ok, [{observed.principal.uid, access_observation(user)} | observations]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp access_observation(%{"status" => status}) when is_map(status) do
    cond do
      status["is_resigned"] == true -> "departure"
      status["is_exited"] == true -> "enterprise_exit"
      status["is_frozen"] == true -> "suspended"
      Enum.all?(~w(is_resigned is_exited is_frozen), &(status[&1] == false)) -> :healthy
      true -> :unknown
    end
  end

  defp access_observation(_), do: :unknown

  defp merge_user(existing, next) do
    Map.merge(existing, next, fn
      "department_ids", left, right -> merge_lists(left, right)
      _key, _left, right -> right
    end)
  end

  defp merge_lists(left, right) do
    [left, right]
    |> Enum.flat_map(fn
      values when is_list(values) -> values
      _value -> []
    end)
    |> Enum.uniq()
  end

  @doc """
  Applies contact change events to every identity-provider consumer.
  """
  @spec handle_contact_event(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_contact_event(event_type, %Event{} = event, consumers) do
    consumers
    |> Enum.filter(&match?(%{kind: :identity_provider}, &1))
    |> Enum.map(&handle_contact_event_for_consumer(&1, event_type, event))
    |> collect_results()
  end

  defp handle_contact_event_for_consumer(
         %{provider_id: provider_id},
         event_type,
         %Event{} = event
       ) do
    content = event.content || %{}
    user = fetch_map(content, "object", fetch_map(content, "user", content))
    user = Map.merge(fetch_map(content, "old_object", %{}), user)
    ids = subject_candidates(user, identity_email(user))
    reason = if event_type == "contact.user.deleted_v3", do: "departure"

    event_id =
      event.id ||
        "missing-id:" <>
          Base.encode16(:crypto.hash(:sha256, Ankole.JSON.encode!(content)), case: :lower)

    time =
      if event.created_at,
        do: DateTime.from_unix!(DateTime.to_unix(event.created_at, :microsecond), :microsecond)

    DirectoryAccess.receive_event(provider_id, %{
      event_id: event_id,
      event_type: event_type,
      external_ids: ids,
      reason: reason,
      provider_time: time
    })
  end

  defp user_info(client, access_token) do
    FeishuOpenAPI.get(client, "/open-apis/authen/v1/user_info", user_access_token: access_token)
  end

  defp ensure_department_group(provider_id, department) when is_map(department) do
    with {:ok, department_id} <- department_id(department),
         {:ok, _group} <-
           Directory.ensure_group(provider_id, %Directory.Group{
             external_id: department_id,
             kind: "department",
             display_name: department_display_name(department, department_id),
             parent_external_id: department_parent_id(department),
             provider_metadata: %{
               "lark" =>
                 compact_metadata_map(%{
                   "department_id" => department_id,
                   "open_department_id" => optional_text(department, "open_department_id"),
                   "parent_department_id" => optional_text(department, "parent_department_id"),
                   "member_count" => MapHelpers.fetch_value(department, "member_count"),
                   "primary_member_count" =>
                     MapHelpers.fetch_value(department, "primary_member_count")
                 })
             }
           }) do
      :ok
    end
  end

  defp department_display_name(department, department_id) do
    optional_text(department, "name") || "Lark Department #{department_id}"
  end

  defp department_parent_id(department) do
    optional_text(department, "parent_department_id") || optional_text(department, "parent_id")
  end

  @doc """
  Fetches contact email, mobile, and name for one inbound author, best effort.

  SignalsGateway calls this only when an unmatched sender needs a contact
  match or a pending-list entry. Cross-tenant senders and missing contact
  scopes fail soft with an error the gateway logs and ignores.
  """
  @spec hydrate_author(map(), map()) :: {:ok, map()} | {:error, term()}
  def hydrate_author(config, author) when is_map(config) and is_map(author) do
    with {:ok, subject_id, id_type} <- hydration_subject(author) do
      case FeishuOpenAPI.get(Config.client(config), "contact/v3/users/:user_id",
             path_params: %{user_id: subject_id},
             query: [user_id_type: id_type]
           ) do
        {:ok, %{"data" => %{"user" => user}}} when is_map(user) ->
          hydrated_author(user, author)

        {:ok, _body} ->
          {:ok, %{}}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp hydration_subject(author) do
    metadata = fetch_map(author, "metadata", %{})

    cond do
      id = optional_text(metadata, "user_id") -> {:ok, id, "user_id"}
      id = optional_text(metadata, "union_id") -> {:ok, id, "union_id"}
      id = optional_text(metadata, "open_id") -> {:ok, id, "open_id"}
      true -> {:error, :missing_author_subject}
    end
  end

  defp hydrated_author(user, author) do
    metadata = fetch_map(author, "metadata", %{})
    email = identity_email(user)

    candidates =
      SubjectIdentity.candidates(%{
        "email" => email,
        "user_id" =>
          optional_text(user, "user_id") ||
            optional_text(user, "id") || optional_text(metadata, "user_id"),
        "union_id" => optional_text(user, "union_id") || optional_text(metadata, "union_id"),
        "open_id" => optional_text(user, "open_id") || optional_text(metadata, "open_id")
      })

    extra = %{
      "email" => email,
      "mobile" => normalized_mobile(user),
      "display_name" => display_name(user)
    }

    case candidates do
      [primary | alternates] ->
        {:ok,
         extra
         |> Map.put("platform_subject", primary)
         |> Map.put("platform_subject_alternates", alternates)}

      [] ->
        {:ok, extra}
    end
  end

  defp hydrate_contact_user(client, user_info) when is_map(user_info) do
    user_id =
      optional_text(user_info, "user_id") ||
        get_in(user_info, ["data", "user_id"]) ||
        get_in(user_info, ["data", "user", "user_id"])

    case user_id do
      id when is_binary(id) ->
        # OIDC user-info is not as rich as the contact API. Hydration is
        # best-effort so login can still succeed if contact lookup is unavailable.
        case FeishuOpenAPI.get(client, "contact/v3/users/:user_id",
               path_params: %{user_id: id},
               query: [user_id_type: "user_id"]
             ) do
          {:ok, %{"data" => %{"user" => user}}} when is_map(user) ->
            {:ok, Map.merge(user_info, user)}

          {:ok, _body} ->
            {:ok, user_info}

          {:error, reason} ->
            Logging.warning(
              "lark_adapter.identity_provider.contact_hydration_failed",
              "lark adapter contact hydration failed",
              %{
                reason: inspect(reason)
              }
            )

            {:ok, user_info}
        end

      nil ->
        {:ok, user_info}
    end
  end

  defp directory_user_key(user) do
    case optional_text(user, "user_id") ||
           optional_text(user, "id") ||
           List.first(subject_candidates(user, identity_email(user))) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, :missing_platform_subject}
    end
  end

  defp department_id(department) do
    case optional_text(department, "department_id") || optional_text(department, "id") do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, :missing_department_id}
    end
  end

  defp display_name(user) do
    optional_text(user, "name") ||
      optional_text(user, "en_name") ||
      optional_text(user, "nickname") ||
      optional_text(user, "user_id")
  end

  defp avatar_url(user) do
    avatar = fetch_map(user, "avatar", %{})
    optional_text(avatar, "avatar_240") || optional_text(avatar, "avatar_origin")
  end

  defp enterprise_email(user) do
    optional_text(user, "enterprise_email") || optional_text(user, "work_email")
  end

  defp identity_email(user) do
    enterprise_email(user) || optional_text(user, "email")
  end

  defp subject_candidates(user, email) do
    SubjectIdentity.candidates(%{
      "email" => email,
      "user_id" => optional_text(user, "user_id") || optional_text(user, "id"),
      "union_id" => optional_text(user, "union_id"),
      "open_id" => optional_text(user, "open_id")
    })
  end

  defp normalized_mobile(user) do
    user
    |> optional_text("mobile")
    |> phone_candidates()
    |> Enum.find_value(fn candidate ->
      case NativeKernel.phone_normalize_e164(candidate) do
        normalized when is_binary(normalized) -> normalized
        {:error, _reason} -> nil
      end
    end)
  end

  defp phone_candidates(nil), do: []

  defp phone_candidates(phone) when is_binary(phone) do
    trimmed = String.trim(phone)
    digits = String.replace(trimmed, ~r/\D/, "")

    case String.length(digits) == 11 and String.starts_with?(digits, "1") do
      true -> [trimmed, "+86" <> digits]
      false -> [trimmed]
    end
  end
end
