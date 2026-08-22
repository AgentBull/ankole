defmodule Ankole.Plugins.LarkAdapter.IdentityProvider do
  @moduledoc """
  Lark / Feishu identity-provider adapter functions for Principals.
  """

  alias Ankole.AuthZ
  alias Ankole.IdentityProviders.Directory
  alias Ankole.IdentityProviders.DirectorySync
  alias Ankole.Kernel, as: NativeKernel
  alias Ankole.Logging
  alias Ankole.Plugins.LarkAdapter.Config
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
    with {:ok, user_id} <- user_id(user) do
      department_ids = fetch_list(user, "department_ids")

      Directory.upsert_user(
        provider_id,
        %{
          provider: provider_id,
          external_id: user_id,
          display_name: display_name(user),
          avatar_url: avatar_url(user),
          email: enterprise_email(user) || optional_text(user, "email"),
          mobile: normalized_mobile(user),
          job_title: optional_text(user, "job_title"),
          metadata:
            compact_metadata_map(%{
              "open_id" => optional_text(user, "open_id"),
              "union_id" => optional_text(user, "union_id"),
              "tenant_key" => optional_text(user, "tenant_key"),
              "employee_no" => optional_text(user, "employee_no"),
              "department_ids" => department_ids
            })
        },
        [group_external_ids: department_ids] ++ Keyword.take(opts, [:directory_group_index])
      )
    end
  end

  @doc """
  Runs a full directory sync and stops on the first write or provider error.
  """
  @spec sync_directory(String.t(), map(), keyword()) ::
          {:ok, %{users: non_neg_integer(), departments: non_neg_integer()}} | {:error, term()}
  def sync_directory(provider_id, config, _opts \\ [])
      when is_binary(provider_id) and is_map(config) do
    with {:ok, %{departments: departments, department_ids: department_ids}} <-
           sync_directory_departments(provider_id, config),
         {:ok, %{users: users}} <- sync_directory_users(provider_id, config, department_ids) do
      {:ok, %{users: users, departments: departments}}
    end
  end

  defp sync_directory_users(provider_id, config, department_ids) do
    client = Config.client(config)
    page_size = get_in(config, ["sync", "pageSize"]) || 50

    with {:ok, users} <- collect_directory_users(client, department_ids, page_size),
         {:ok, directory_group_index} <- AuthZ.external_directory_group_index(provider_id) do
      users
      |> Map.values()
      |> Enum.reduce_while({:ok, 0}, fn user, {:ok, count} ->
        case upsert_user(provider_id, user, directory_group_index: directory_group_index) do
          {:ok, _} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, count} -> {:ok, %{users: count}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp sync_directory_departments(provider_id, config) do
    client = Config.client(config)
    page_size = get_in(config, ["sync", "pageSize"]) || 50

    client
    |> Pagination.stream("contact/v3/departments/:department_id/children",
      path_params: %{department_id: "0"},
      query: [
        department_id_type: "department_id",
        fetch_child: true,
        page_size: page_size,
        user_id_type: "user_id"
      ],
      items: ["data", "items"]
    )
    |> Enum.reduce_while({:ok, %{count: 0, department_ids: []}}, fn
      {:ok, department}, {:ok, acc} ->
        case ensure_department_group(provider_id, department) do
          :ok ->
            department_ids =
              case department_id(department) do
                {:ok, id} -> [id | acc.department_ids]
                {:error, _reason} -> acc.department_ids
              end

            {:cont, {:ok, %{count: acc.count + 1, department_ids: department_ids}}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, result} ->
        {:ok, %{departments: result.count, department_ids: Enum.reverse(result.department_ids)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp collect_directory_users(client, department_ids, page_size) do
    department_ids
    |> root_department_first()
    |> Enum.reduce_while({:ok, %{}}, fn department_id, {:ok, users} ->
      case collect_department_users(client, department_id, page_size, users) do
        {:ok, users} -> {:cont, {:ok, users}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp root_department_first(department_ids) do
    ["0" | department_ids]
    |> Enum.uniq()
  end

  defp collect_department_users(client, department_id, page_size, users) do
    client
    |> Pagination.stream("contact/v3/users",
      query: [
        department_id: department_id,
        department_id_type: "department_id",
        page_size: page_size,
        user_id_type: "user_id"
      ],
      items: ["data", "items"]
    )
    |> Enum.reduce_while({:ok, users}, fn
      {:ok, user}, {:ok, acc} ->
        case user_id(user) do
          {:ok, user_id} -> {:cont, {:ok, Map.update(acc, user_id, user, &merge_user(&1, user))}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {:error, reason}, _acc ->
        {:halt, {:error, reason}}
    end)
  end

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

    cond do
      String.starts_with?(event_type, "contact.user.") ->
        user = fetch_map(content, "user", content)

        case user_id(user) do
          {:ok, _id} -> upsert_user(provider_id, user)
          # Some contact events omit enough user fields that an incremental merge
          # would risk writing a low-quality Principal. Asking for a full sync is
          # safer than guessing which identifier the event meant.
          {:error, _reason} -> enqueue_full_sync(provider_id, :missing_user_id)
        end

      String.starts_with?(event_type, "contact.department.") ->
        enqueue_full_sync(provider_id, :contact_department_changed)

      event_type == "contact.scope.updated_v3" ->
        enqueue_full_sync(provider_id, :contact_scope_updated)

      true ->
        {:ok, %{status: :ignored_unknown_contact_event}}
    end
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

  defp enqueue_full_sync(provider_id, reason) do
    case DirectorySync.enqueue_sync(provider_id,
           reason: reason,
           source: "lark_contact_event"
         ) do
      {:ok, _job} -> {:ok, %{status: :full_sync_enqueued, reason: reason}}
      {:error, error} -> {:error, {:full_sync_enqueue_failed, reason, error}}
    end
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
          {:ok,
           %{
             "email" => enterprise_email(user) || optional_text(user, "email"),
             "mobile" => normalized_mobile(user),
             "display_name" => display_name(user)
           }}

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
      id = optional_text(metadata, "open_id") -> {:ok, id, "open_id"}
      id = optional_text(metadata, "union_id") -> {:ok, id, "union_id"}
      true -> {:error, :missing_author_subject}
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

  defp user_id(user) do
    case optional_text(user, "user_id") || optional_text(user, "id") do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, :missing_user_id}
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
