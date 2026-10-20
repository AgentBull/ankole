defmodule Ankole.Plugins.LarkAdapter.IMGroups do
  @moduledoc """
  Lark IM group synchronization for Signal Bindings for external conversations.
  """

  import Ecto.Query, warn: false

  alias Ankole.Signals.Bindings
  alias Ankole.AuthZ.Store, as: AuthZStore
  alias Ankole.Logging
  alias Ankole.Plugins.ChannelSync
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Plugins.LarkAdapter.SubjectIdentity
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Principals
  alias Ankole.Repo

  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.IMGroupMembers
  alias Ankole.Conversations.IMGroupProjection
  alias FeishuOpenAPI.Event
  alias FeishuOpenAPI.Pagination

  import MapHelpers,
    only: [
      compact_metadata_map: 1,
      collect_results: 1,
      fetch_map: 3,
      optional_text: 2
    ]

  @default_page_size 50

  @bot_added "im.chat.member.bot.added_v1"
  @bot_deleted "im.chat.member.bot.deleted_v1"
  @user_added "im.chat.member.user.added_v1"
  @user_deleted "im.chat.member.user.deleted_v1"
  @chat_updated "im.chat.updated_v1"
  @chat_disbanded "im.chat.disbanded_v1"

  @doc false
  @spec event_types() :: [String.t()]
  def event_types do
    [
      @bot_added,
      @bot_deleted,
      @user_added,
      @user_deleted,
      @chat_updated,
      @chat_disbanded
    ]
  end

  @doc false
  @spec handle_binding_saved(Binding.t(), map()) :: :ok | {:error, term()}
  def handle_binding_saved(%Binding{agent_uid: agent_uid, name: binding_name}, config)
      when is_map(config) do
    case ChannelSync.enqueue_binding(
           Ankole.Plugins.LarkAdapter.Jobs.SyncIMGroups,
           agent_uid,
           binding_name,
           reason: "binding_saved",
           source: "signal_binding"
         ) do
      {:ok, _job} -> ConnectionReconciler.reconcile_async()
      {:error, _reason} = error -> error
    end
  end

  @spec enqueue_chat_refresh(AdapterContext.t(), map(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  defp enqueue_chat_refresh(%AdapterContext{} = context, _config, chat_id, opts)
       when is_binary(chat_id) do
    %{
      "agent_uid" => String.downcase(context.agent_uid),
      "binding_name" => context.binding_name,
      "chat_id" => chat_id,
      "reason" => to_string(Keyword.get(opts, :reason, "event"))
    }
    |> Ankole.Plugins.LarkAdapter.Jobs.RefreshIMGroup.new()
    |> Oban.insert()
  end

  @doc false
  @spec maybe_enqueue_missing_channel_refresh(map(), map()) :: :ok
  def maybe_enqueue_missing_channel_refresh(
        %{context: %AdapterContext{} = context, config: config},
        %{channel: %{kind: :im_group}, provider_conversation_id: provider_conversation_id}
      )
      when is_binary(provider_conversation_id) and is_map(config) do
    case Ankole.Conversations.External.get_conversation(
           Repo,
           provider_conversation_id
         ) do
      %Conversation{principal_group_id: group_id} when is_binary(group_id) ->
        :ok

      %Conversation{} ->
        chat_id =
          provider_conversation_id
          |> lark_channel_chat_id()
          |> Kernel.||(get_in(config, ["chat_id"]))

        enqueue_refresh_if_chat_id(context, config, chat_id, "missing_channel_principal_group")

      nil ->
        :ok
    end
  end

  def maybe_enqueue_missing_channel_refresh(_consumer, _input), do: :ok

  @doc false
  @spec sync_binding(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def sync_binding(agent_uid, binding_name)
      when is_binary(agent_uid) and is_binary(binding_name) do
    with {:ok, binding} <- Ankole.Signals.Bindings.get_binding(agent_uid, binding_name),
         {:ok, config} <- Bindings.binding_config(binding, Config),
         {:ok, chats} <- list_joined_chats(config),
         context <- binding_context(binding, config),
         {:ok, synced} <- sync_joined_chats(context, config, chats),
         {:ok, left} <-
           IMGroupProjection.mark_missing_left(
             namespace(config),
             Enum.map(chats, &chat_id!/1),
             context
           ) do
      {:ok,
       %{
         binding: %{agent_uid: binding.agent_uid, binding_name: binding.name},
         synced_chats: synced,
         marked_left: left
       }}
    else
      {:error, :binding_disabled} ->
        {:ok,
         %{
           status: :skipped_binding_disabled,
           binding: %{agent_uid: String.downcase(agent_uid), binding_name: binding_name}
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec refresh_chat(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_chat(agent_uid, binding_name, chat_id)
      when is_binary(agent_uid) and is_binary(binding_name) and is_binary(chat_id) do
    with {:ok, binding} <- Ankole.Signals.Bindings.get_binding(agent_uid, binding_name),
         {:ok, config} <- Bindings.binding_config(binding, Config),
         context <- binding_context(binding, config),
         {:ok, chat} <- fetch_chat_info(config, chat_id),
         {:ok, group} <-
           IMGroupProjection.ensure_group(
             namespace(config),
             chat_id,
             chat_attrs(config, chat),
             context,
             group_projection_options(namespace(config), chat_id, chat_attrs(config, chat))
           ),
         {:ok, principal_uids} <- member_principal_uids(config, chat_id),
         # The API snapshot can be older than a just-arrived member event. The
         # per-chat lock keeps writes ordered; later events or refreshes converge
         # stale snapshots.
         {:ok, replace} <- IMGroupMembers.replace_members(group.id, principal_uids) do
      {:ok,
       %{
         group_id: group.id,
         chat_id: chat_id,
         synced_members: length(principal_uids),
         removed_memberships: replace.removed_memberships
       }}
    end
  end

  @doc false
  @spec handle_im_event(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_im_event(event_type, %Event{} = event, consumers) when is_binary(event_type) do
    result =
      consumers
      |> Enum.filter(&match?(%{kind: :chat}, &1))
      |> Enum.map(&handle_im_event_for_consumer(&1, event_type, event))
      |> collect_results()

    maybe_log_missing_platform_subject(event_type, event, result)
    result
  end

  defp handle_im_event_for_consumer(
         %{context: %AdapterContext{} = context, config: config} = consumer,
         event_type,
         %Event{} = event
       ) do
    content = event.content || %{}

    case chat_id(content) do
      {:ok, chat_id} ->
        dispatch_im_event(consumer, context, config, event_type, event, content, chat_id)

      {:error, _reason} ->
        {:ok, %{status: :ignored_missing_chat_id, event_type: event_type}}
    end
  end

  defp dispatch_im_event(_consumer, context, config, @bot_added, _event, _content, chat_id) do
    enqueue_chat_refresh(context, config, chat_id, reason: "bot_joined")
    |> enqueue_result(:refresh_enqueued)
  end

  defp dispatch_im_event(_consumer, context, config, @bot_deleted, _event, _content, chat_id) do
    IMGroupProjection.mark_left(namespace(config), chat_id, context)
  end

  defp dispatch_im_event(_consumer, _context, config, @chat_disbanded, _event, _content, chat_id) do
    IMGroupProjection.mark_all_left(namespace(config), chat_id)
  end

  defp dispatch_im_event(_consumer, context, config, @chat_updated, _event, _content, chat_id) do
    enqueue_chat_refresh(context, config, chat_id, reason: "chat_updated")
    |> enqueue_result(:refresh_enqueued)
  end

  defp dispatch_im_event(_consumer, context, config, @user_added, _event, content, chat_id) do
    case member_subject_candidates(content) do
      [_primary | _aliases] ->
        with {:ok, group} <- IMGroupProjection.get_group(namespace(config), chat_id),
             {:ok, observed} <- upsert_member_principal(config, content),
             {:ok, _membership} <-
               Repo.transact(fn repo ->
                 AuthZStore.add_synced_group_member(
                   repo,
                   group.id,
                   :im_group,
                   observed.principal.uid
                 )
               end) do
          {:ok,
           %{status: :member_added, principal_uid: observed.principal.uid, group_id: group.id}}
        else
          {:error, :not_found} ->
            enqueue_chat_refresh(context, config, chat_id, reason: "member_added_missing_group")
            |> enqueue_result(:refresh_enqueued)

          {:error, _reason} = error ->
            error
        end

      [] ->
        ignored_missing_platform_subject()
    end
  end

  defp dispatch_im_event(_consumer, context, config, @user_deleted, _event, content, chat_id) do
    case member_subject_candidates(content) do
      [_primary | _aliases] = external_ids ->
        remove_member_from_group(context, config, chat_id, external_ids)

      [] ->
        ignored_missing_platform_subject()
    end
  end

  defp dispatch_im_event(_consumer, _context, _config, event_type, _event, _content, _chat_id) do
    {:ok, %{status: :ignored_unknown_im_event, event_type: event_type}}
  end

  defp ignored_missing_platform_subject do
    {:ok, %{status: :ignored_missing_platform_subject, reason: :missing_platform_subject}}
  end

  defp maybe_log_missing_platform_subject(event_type, %Event{} = event, {:ok, results}) do
    if Enum.any?(results, &(Map.get(&1, :reason) == :missing_platform_subject)) do
      content = event.content || %{}
      member = fetch_map(content, "member", content)
      identity = member_identity(content)

      Logging.warning(
        "lark_adapter.im_groups.missing_platform_subject",
        "lark adapter ignored IM group member event without email or a supported user id",
        %{
          event_id: event.id,
          event_type: event_type,
          chat_id: chat_id(content) |> chat_id_for_log(),
          member_type: member_type(member),
          open_id: identity["open_id"],
          union_id: identity["union_id"],
          tenant_key: event.tenant_key
        }
      )
    end

    :ok
  end

  defp maybe_log_missing_platform_subject(_event_type, _event, _result), do: :ok

  defp chat_id_for_log({:ok, chat_id}), do: chat_id
  defp chat_id_for_log({:error, _reason}), do: nil

  defp sync_joined_chats(context, config, chats) do
    chats
    |> Enum.reduce_while({:ok, 0}, fn chat, {:ok, count} ->
      chat_id = chat_id!(chat)

      with {:ok, group} <-
             IMGroupProjection.ensure_group(
               namespace(config),
               chat_id,
               chat_attrs(config, chat),
               context,
               group_projection_options(namespace(config), chat_id, chat_attrs(config, chat))
             ),
           {:ok, principal_uids} <- member_principal_uids(config, chat_id),
           # Writes are serialized per chat, but the provider snapshot can still
           # be older than a just-arrived member event. Later member events or
           # refresh jobs converge the group again.
           {:ok, _replace} <- IMGroupMembers.replace_members(group.id, principal_uids) do
        {:cont, {:ok, count + 1}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp list_joined_chats(config) do
    client = Config.client(config)
    page_size = get_in(config, ["sync", "pageSize"]) || @default_page_size

    client
    |> Pagination.stream("im/v1/chats",
      query: [page_size: page_size, user_id_type: "user_id"],
      items: ["data", "items"]
    )
    |> collect_paginated_items()
  end

  defp fetch_chat_info(config, chat_id) do
    client = Config.client(config)

    case FeishuOpenAPI.get(client, "im/v1/chats/:chat_id",
           path_params: %{chat_id: chat_id},
           query: [user_id_type: "user_id"]
         ) do
      {:ok, %{"data" => %{"chat" => chat}}} when is_map(chat) -> {:ok, chat}
      {:ok, %{"data" => chat}} when is_map(chat) -> {:ok, Map.put_new(chat, "chat_id", chat_id)}
      {:ok, chat} when is_map(chat) -> {:ok, Map.put_new(chat, "chat_id", chat_id)}
      {:error, _reason} = error -> error
    end
  end

  defp member_principal_uid(config, chat_id, member) do
    cond do
      ignored_member?(member) ->
        {:ok, nil}

      member_subject_candidates(member) == [] ->
        Logging.warning(
          "lark_adapter.im_groups.member_missing_platform_subject",
          "lark adapter skipped IM group member without email or a supported user id",
          %{chat_id: chat_id, member: inspect(member)}
        )

        {:ok, nil}

      true ->
        with {:ok, observed} <- upsert_member_principal(config, member),
             do: {:ok, observed.principal.uid}
    end
  end

  defp member_principal_uids(config, chat_id) do
    config
    |> list_members(chat_id)
    |> case do
      {:ok, members} ->
        members
        |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
          case member_principal_uid(config, chat_id, member) do
            {:ok, nil} -> {:cont, {:ok, acc}}
            {:ok, uid} -> {:cont, {:ok, [uid | acc]}}
            {:error, _reason} = error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, uids} -> {:ok, uids |> Enum.uniq() |> Enum.sort()}
          {:error, reason} -> {:error, reason}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp list_members(config, chat_id) do
    client = Config.client(config)
    page_size = get_in(config, ["sync", "pageSize"]) || @default_page_size

    client
    |> Pagination.stream("im/v1/chats/:chat_id/members",
      path_params: %{chat_id: chat_id},
      query: [member_id_type: "user_id", page_size: page_size],
      items: ["data", "items"]
    )
    |> collect_paginated_items()
  end

  defp collect_paginated_items(stream) do
    stream
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, item}, {:ok, acc} -> {:cont, {:ok, [item | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp chat_attrs(config, chat) do
    %{
      "name" => chat_name(chat),
      "app_id" => Map.fetch!(config, "appID"),
      "domain" => Map.fetch!(config, "domain"),
      "visibility" => optional_text(chat, "visibility"),
      "raw_payload" => chat
    }
  end

  defp chat_name(chat) do
    optional_text(chat, "name") ||
      optional_text(chat, "chat_name") ||
      optional_text(chat, "display_name")
  end

  defp group_projection_options(namespace, chat_id, attrs) do
    [
      default_display_name: "Lark IM Group #{chat_id}",
      binding_metadata:
        compact_metadata_map(%{
          "provider" => namespace,
          "externalKind" => "im_group",
          "externalID" => chat_id,
          "name" => optional_text(attrs, "name"),
          "app_id" => optional_text(attrs, "app_id"),
          "domain" => optional_text(attrs, "domain"),
          "syncedAt" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
        }),
      channel: %{
        on_conflict: :keep_existing,
        fact: %{
          provider_conversation_id: Inbound.provider_conversation_id(chat_id),
          channel_kind: :im_group,
          reply_mode: :entry,
          channel_name: optional_text(attrs, "name"),
          channel_visibility: optional_text(attrs, "visibility"),
          channel_metadata:
            compact_metadata_map(%{
              "chat_id" => chat_id,
              "domain" => optional_text(attrs, "domain"),
              "app_id" => optional_text(attrs, "app_id")
            }),
          channel_raw_payload: fetch_map(attrs, "raw_payload", %{})
        }
      }
    ]
  end

  defp remove_member_from_group(context, config, chat_id, external_ids) do
    case IMGroupProjection.get_group(namespace(config), chat_id) do
      {:ok, group} ->
        remove_member_from_existing_group(context, config, chat_id, group, external_ids)

      {:error, :not_found} ->
        enqueue_chat_refresh(context, config, chat_id, reason: "member_removed_missing_group")
        |> enqueue_result(:refresh_enqueued)
    end
  end

  defp remove_member_from_existing_group(context, config, chat_id, group, external_ids) do
    with {:ok, principal_uid} <-
           resolve_member_principal_uid(namespace(config), external_ids) do
      case Repo.transact(fn repo ->
             AuthZStore.remove_synced_group_member(repo, group.id, :im_group, principal_uid)
           end) do
        {:ok, :deleted} ->
          {:ok, %{status: :member_removed, principal_uid: principal_uid, group_id: group.id}}

        {:error, :not_found} ->
          {:ok,
           %{status: :member_already_removed, principal_uid: principal_uid, group_id: group.id}}

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :not_found} ->
        enqueue_chat_refresh(context, config, chat_id, reason: "member_removed_missing_identity")
        |> enqueue_result(:refresh_enqueued)
    end
  end

  defp upsert_member_principal(config, member) do
    identity = member_identity(member)

    case SubjectIdentity.candidates(identity) do
      [external_id | external_ids] ->
        %{
          provider: namespace(config),
          external_id: external_id,
          external_ids: external_ids,
          display_name: member_display_name(member),
          metadata:
            compact_metadata_map(%{
              "user_id" => identity["user_id"],
              "open_id" => identity["open_id"],
              "union_id" => identity["union_id"],
              "member_type" => member_type(member)
            })
        }
        |> Ankole.Attrs.maybe_put(:email, identity["email"])
        |> Principals.upsert_platform_subject_human()

      [] ->
        {:error, :missing_platform_subject}
    end
  end

  defp resolve_member_principal_uid(provider, external_ids) do
    Enum.reduce_while(external_ids, {:error, :not_found}, fn external_id, _not_found ->
      case Principals.resolve_platform_subject_uid(provider, external_id) do
        {:ok, _principal_uid} = resolved -> {:halt, resolved}
        {:error, :not_found} -> {:cont, {:error, :not_found}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp member_subject_candidates(member) do
    member
    |> member_identity()
    |> SubjectIdentity.candidates()
  end

  defp member_identity(member) do
    nodes = member_identity_nodes(member)

    %{
      "email" =>
        member_identity_value(nodes, "email") ||
          member_identity_value(nodes, "enterprise_email") ||
          member_identity_value(nodes, "work_email"),
      "user_id" => member_identity_value(nodes, "user_id"),
      "union_id" => member_identity_value(nodes, "union_id"),
      "open_id" => member_identity_value(nodes, "open_id")
    }
  end

  defp member_display_name(member) do
    nodes = member_identity_nodes(member)

    member_identity_value(nodes, "name") ||
      member_identity_value(nodes, "member_name") ||
      member_identity_value(nodes, "display_name") ||
      member_identity_value(nodes, "user_id")
  end

  defp member_identity_nodes(member) when is_map(member) do
    nested_member = fetch_map(member, "member", %{})

    [
      member,
      fetch_map(member, "member_id", %{}),
      nested_member,
      fetch_map(nested_member, "member_id", %{})
    ]
  end

  defp member_identity_nodes(_member), do: []

  defp member_identity_value(nodes, key) do
    Enum.find_value(nodes, fn node ->
      optional_text(node, key) || typed_member_id(node, key)
    end)
  end

  defp typed_member_id(node, key) do
    case {optional_text(node, "member_id_type"), optional_text(node, "member_id")} do
      {^key, value} -> value
      _other -> nil
    end
  end

  defp ignored_member?(member), do: member_type(member) in ["bot", "app"]

  defp member_type(member) do
    optional_text(member, "member_type") ||
      optional_text(member, "type") ||
      optional_text(fetch_map(member, "member", %{}), "member_type")
  end

  defp chat_id(map) when is_map(map) do
    chat = fetch_map(map, "chat", map)

    value =
      optional_text(chat, "chat_id") ||
        optional_text(map, "chat_id") ||
        get_in(fetch_map(map, "message", %{}), ["chat_id"])

    case value do
      chat_id when is_binary(chat_id) -> {:ok, chat_id}
      nil -> {:error, :missing_chat_id}
    end
  end

  defp chat_id(_map), do: {:error, :missing_chat_id}

  defp chat_id!(chat) do
    case chat_id(chat) do
      {:ok, chat_id} -> chat_id
      {:error, reason} -> raise ArgumentError, "invalid Lark chat payload: #{inspect(reason)}"
    end
  end

  defp namespace(config), do: Config.subject_namespace(config)

  defp binding_context(%Binding{} = binding, config) do
    AdapterContext.new(
      agent_uid: binding.agent_uid,
      binding_name: binding.name,
      adapter: binding.adapter,
      user_name: Map.get(config, "userName", "Lark / Feishu")
    )
  end

  defp enqueue_refresh_if_chat_id(_context, _config, nil, _reason), do: :ok

  defp enqueue_refresh_if_chat_id(context, config, chat_id, reason) do
    case enqueue_chat_refresh(context, config, chat_id, reason: reason) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "lark_adapter.im_groups.refresh_enqueue_failed",
          "lark adapter could not enqueue IM group refresh",
          %{reason: inspect(reason), chat_id: chat_id}
        )

        :ok
    end
  end

  defp enqueue_result({:ok, %Oban.Job{} = job}, status),
    do: {:ok, %{status: status, job_id: job.id}}

  defp enqueue_result({:error, _reason} = error, _status), do: error

  defp lark_channel_chat_id("lark:" <> encoded), do: URI.decode(encoded)
  defp lark_channel_chat_id(_channel_id), do: nil
end
