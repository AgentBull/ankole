defmodule Ankole.Plugins.LarkAdapter.IMGroups do
  @moduledoc """
  Lark IM group synchronization for SignalsGateway chat bindings.
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.AuthZ
  alias Ankole.AuthZ.ExternalBinding
  alias Ankole.AuthZ.Group
  alias Ankole.AuthZ.Store, as: AuthZStore
  alias Ankole.Logging
  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Plugins.LarkAdapter.MapHelpers
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Binding
  alias Ankole.SignalsGateway.BindingMembership
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Projection
  alias FeishuOpenAPI.Event
  alias FeishuOpenAPI.Pagination

  import MapHelpers,
    only: [
      compact_metadata_map: 1,
      collect_results: 1,
      fetch_map: 3,
      optional_text: 2
    ]

  @im_group_external_kind :im_group
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
    case enqueue_binding_full_sync(agent_uid, binding_name,
           reason: "binding_saved",
           source: "signal_binding"
         ) do
      {:ok, _job} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec enqueue_full_syncs(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue_full_syncs(opts \\ []) do
    source = Keyword.get(opts, :source, "startup")
    reason = Keyword.get(opts, :reason, "startup")

    "lark"
    |> SignalsGateway.list_enabled_bindings(Keyword.take(opts, [:repo]))
    |> Enum.reduce_while({:ok, %{enqueued: [], skipped: []}}, fn binding, {:ok, acc} ->
      case enqueue_binding_full_sync(binding.agent_uid, binding.name,
             reason: reason,
             source: source
           ) do
        {:ok, %Oban.Job{conflict?: true}} ->
          {:cont, {:ok, %{acc | skipped: [{binding.agent_uid, binding.name} | acc.skipped]}}}

        {:ok, %Oban.Job{} = job} ->
          {:cont, {:ok, %{acc | enqueued: [job | acc.enqueued]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, result} ->
        {:ok,
         %{
           enqueued: Enum.reverse(result.enqueued),
           skipped: Enum.reverse(result.skipped)
         }}

      {:error, _reason} = error ->
        error
    end
  end

  @doc false
  @spec enqueue_binding_full_sync(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_binding_full_sync(agent_uid, binding_name, opts \\ [])
      when is_binary(agent_uid) and is_binary(binding_name) do
    %{
      "agent_uid" => String.downcase(agent_uid),
      "binding_name" => binding_name,
      "reason" => to_string(Keyword.get(opts, :reason, "manual")),
      "source" => to_string(Keyword.get(opts, :source, "manual"))
    }
    |> Ankole.Plugins.LarkAdapter.Jobs.SyncIMGroups.new()
    |> Oban.insert()
  end

  @doc false
  @spec enqueue_chat_refresh(AdapterContext.t(), map(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_chat_refresh(%AdapterContext{} = context, _config, chat_id, opts \\ [])
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
        %{channel: %{kind: :im_group}, signal_channel_id: signal_channel_id}
      )
      when is_binary(signal_channel_id) and is_map(config) do
    case Repo.get(Channel, signal_channel_id) do
      %Channel{principal_group_id: group_id} when is_binary(group_id) ->
        :ok

      %Channel{} ->
        chat_id =
          signal_channel_id
          |> lark_channel_chat_id()
          |> Kernel.||(get_in(config, ["chat_id"]))

        enqueue_refresh_if_chat_id(context, config, chat_id, "missing_channel_principal_group")

      nil ->
        :ok
    end
  end

  def maybe_enqueue_missing_channel_refresh(_consumer, _input), do: :ok

  @doc false
  @spec sync_binding(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_binding(agent_uid, binding_name, opts \\ [])
      when is_binary(agent_uid) and is_binary(binding_name) do
    with {:ok, binding} <- SignalsGateway.get_binding(agent_uid, binding_name),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref),
         {:ok, chats} <- list_joined_chats(config, opts),
         context <- binding_context(binding, config),
         {:ok, synced} <- sync_joined_chats(context, config, chats, opts),
         {:ok, left} <- mark_missing_chats_left(context, config, Enum.map(chats, &chat_id!/1)) do
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
  @spec refresh_chat(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def refresh_chat(agent_uid, binding_name, chat_id, opts \\ [])
      when is_binary(agent_uid) and is_binary(binding_name) and is_binary(chat_id) do
    with {:ok, binding} <- SignalsGateway.get_binding(agent_uid, binding_name),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref),
         context <- binding_context(binding, config),
         {:ok, chat} <- fetch_chat_info(config, chat_id, opts),
         {:ok, group} <-
           ensure_lark_im_group(
             namespace(config),
             chat_id,
             chat_attrs(config, chat),
             context
           ),
         {:ok, principal_uids} <- member_principal_uids(config, chat_id, opts),
         # The API snapshot can be older than a just-arrived member event. The
         # per-chat lock keeps writes ordered; later events or refreshes converge
         # stale snapshots.
         {:ok, replace} <- AuthZ.replace_static_group_members(group.id, :im_group, principal_uids) do
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
  @spec ensure_lark_im_group(String.t(), String.t(), map(), AdapterContext.t()) ::
          {:ok, Group.t()} | {:error, term()}
  def ensure_lark_im_group(namespace, chat_id, attrs, %AdapterContext{} = context)
      when is_binary(namespace) and is_binary(chat_id) and is_map(attrs) do
    Repo.transact(fn repo ->
      with :ok <- lock_chat(repo, namespace, chat_id),
           {:ok, group} <-
             ensure_lark_im_group_in_tx(repo, namespace, chat_id, attrs, context) do
        {:ok, group}
      end
    end)
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
    mark_participant_left(namespace(config), chat_id, context)
  end

  defp dispatch_im_event(_consumer, _context, config, @chat_disbanded, _event, _content, chat_id) do
    mark_all_participants_left(namespace(config), chat_id)
  end

  defp dispatch_im_event(_consumer, context, config, @chat_updated, _event, _content, chat_id) do
    enqueue_chat_refresh(context, config, chat_id, reason: "chat_updated")
    |> enqueue_result(:refresh_enqueued)
  end

  defp dispatch_im_event(_consumer, context, config, @user_added, _event, content, chat_id) do
    case member_user_id(content) do
      {:ok, user_id} ->
        with {:ok, group} <- fetch_im_group(namespace(config), chat_id),
             {:ok, observed} <- upsert_member_principal(config, member_payload(content, user_id)),
             {:ok, _membership} <- AuthZ.add_principal_to_group(observed.principal.uid, group.id) do
          {:ok,
           %{status: :member_added, principal_uid: observed.principal.uid, group_id: group.id}}
        else
          {:error, :not_found} ->
            enqueue_chat_refresh(context, config, chat_id, reason: "member_added_missing_group")
            |> enqueue_result(:refresh_enqueued)

          {:error, _reason} = error ->
            error
        end

      {:error, _reason} ->
        ignored_missing_platform_subject()
    end
  end

  defp dispatch_im_event(_consumer, context, config, @user_deleted, _event, content, chat_id) do
    case member_user_id(content) do
      {:ok, user_id} ->
        remove_member_from_group(context, config, chat_id, user_id)

      {:error, _reason} ->
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
      member_ids = fetch_map(member, "member_id", member)

      Logging.warning(
        "lark_adapter.im_groups.missing_platform_subject",
        "lark adapter ignored IM group member event without user_id",
        %{
          event_id: event.id,
          event_type: event_type,
          chat_id: chat_id(content) |> chat_id_for_log(),
          member_type: member_type(member),
          open_id: optional_text(member_ids, "open_id"),
          union_id: optional_text(member_ids, "union_id"),
          tenant_key: event.tenant_key
        }
      )
    end

    :ok
  end

  defp maybe_log_missing_platform_subject(_event_type, _event, _result), do: :ok

  defp chat_id_for_log({:ok, chat_id}), do: chat_id
  defp chat_id_for_log({:error, _reason}), do: nil

  defp sync_joined_chats(context, config, chats, opts) do
    chats
    |> Enum.reduce_while({:ok, 0}, fn chat, {:ok, count} ->
      chat_id = chat_id!(chat)

      with {:ok, group} <-
             ensure_lark_im_group(
               namespace(config),
               chat_id,
               chat_attrs(config, chat),
               context
             ),
           {:ok, principal_uids} <- member_principal_uids(config, chat_id, opts),
           # Writes are serialized per chat, but the provider snapshot can still
           # be older than a just-arrived member event. Later member events or
           # refresh jobs converge the group again.
           {:ok, _replace} <-
             AuthZ.replace_static_group_members(group.id, :im_group, principal_uids) do
        {:cont, {:ok, count + 1}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp list_joined_chats(config, opts) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))
    page_size = get_in(config, ["sync", "pageSize"]) || @default_page_size

    client
    |> Pagination.stream("im/v1/chats",
      query: [page_size: page_size, user_id_type: "user_id"],
      items: ["data", "items"]
    )
    |> collect_paginated_items()
  end

  defp fetch_chat_info(config, chat_id, opts) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))

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

  defp member_principal_uids(config, chat_id, opts) do
    config
    |> list_members(chat_id, opts)
    |> case do
      {:ok, members} ->
        members
        |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
          cond do
            ignored_member?(member) ->
              {:cont, {:ok, acc}}

            true ->
              case member_user_id(member) do
                {:ok, user_id} ->
                  case upsert_member_principal(config, Map.put(member, "user_id", user_id)) do
                    {:ok, observed} -> {:cont, {:ok, [observed.principal.uid | acc]}}
                    {:error, reason} -> {:halt, {:error, reason}}
                  end

                {:error, _reason} ->
                  Logging.warning(
                    "lark_adapter.im_groups.member_missing_user_id",
                    "lark adapter skipped IM group member without user_id",
                    %{
                      chat_id: chat_id,
                      member: inspect(member)
                    }
                  )

                  {:cont, {:ok, acc}}
              end
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

  defp list_members(config, chat_id, opts) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))
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

  defp ensure_lark_im_group_in_tx(repo, namespace, chat_id, attrs, context) do
    case lock_im_group_by_binding(repo, namespace, chat_id) do
      {:ok, group} -> update_im_group_in_tx(repo, group, namespace, chat_id, attrs, context)
      {:error, :not_found} -> create_im_group_in_tx(repo, namespace, chat_id, attrs, context)
    end
  end

  defp create_im_group_in_tx(repo, namespace, chat_id, attrs, context) do
    metadata = BindingMembership.project(%{}, context, :joined)

    with {:ok, group} <-
           %Group{}
           |> Group.changeset(%{
             name: group_name(namespace, chat_id),
             display_name: group_display_name(attrs, chat_id),
             domain: :im_group,
             kind: :static,
             metadata: metadata
           })
           |> repo.insert(),
         {:ok, _binding} <- upsert_im_binding_in_tx(repo, namespace, chat_id, group.id, attrs),
         {:ok, _channel} <- maybe_upsert_group_channel(repo, namespace, chat_id, group, attrs) do
      {:ok, group}
    end
  end

  defp update_im_group_in_tx(repo, %Group{} = group, namespace, chat_id, attrs, context) do
    changes =
      %{
        metadata: BindingMembership.project(group.metadata, context, :joined)
      }
      |> maybe_put_display_name(attrs, chat_id)

    with {:ok, group} <- group |> Group.changeset(changes) |> repo.update(),
         {:ok, _binding} <- upsert_im_binding_in_tx(repo, namespace, chat_id, group.id, attrs),
         {:ok, _channel} <- maybe_upsert_group_channel(repo, namespace, chat_id, group, attrs) do
      {:ok, group}
    end
  end

  defp lock_im_group_by_binding(repo, namespace, chat_id) do
    query =
      im_group_by_binding_query(namespace, chat_id)
      |> lock("FOR UPDATE")

    case repo.one(query) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :not_found}
    end
  end

  defp get_im_group_by_binding(repo, namespace, chat_id) do
    case repo.one(im_group_by_binding_query(namespace, chat_id)) do
      %Group{} = group -> {:ok, group}
      nil -> {:error, :not_found}
    end
  end

  defp im_group_by_binding_query(namespace, chat_id) do
    from(binding in ExternalBinding,
      join: group in Group,
      on: group.id == binding.group_id,
      where:
        binding.provider == ^namespace and binding.external_kind == ^@im_group_external_kind and
          binding.external_id == ^chat_id,
      select: group
    )
  end

  defp upsert_im_binding_in_tx(repo, namespace, chat_id, group_id, attrs) do
    %ExternalBinding{}
    |> ExternalBinding.changeset(%{
      provider: namespace,
      external_kind: :im_group,
      external_id: chat_id,
      group_id: group_id,
      metadata:
        compact_metadata_map(%{
          "provider" => namespace,
          "externalKind" => "im_group",
          "externalID" => chat_id,
          "name" => optional_text(attrs, "name"),
          "app_id" => optional_text(attrs, "app_id"),
          "domain" => optional_text(attrs, "domain"),
          "syncedAt" => DateTime.utc_now(:microsecond) |> DateTime.to_iso8601()
        })
    })
    |> repo.insert(
      conflict_target: [:provider, :external_kind, :external_id],
      on_conflict: {:replace, [:group_id, :metadata, :updated_at]},
      returning: true
    )
  end

  defp maybe_upsert_group_channel(repo, namespace, chat_id, %Group{} = group, attrs) do
    signal_channel_id = Inbound.signal_channel_id(chat_id)

    case repo.get(Channel, signal_channel_id) do
      %Channel{principal_group_id: group_id} when is_binary(group_id) ->
        case group_id == group.id do
          true ->
            Projection.upsert_channel(
              repo,
              channel_fact(chat_id, group.id, attrs),
              DateTime.utc_now(:microsecond)
            )

          false ->
            log_channel_namespace_conflict(repo, signal_channel_id, namespace, group_id, group.id)

            Projection.upsert_channel(
              repo,
              channel_fact(chat_id, nil, attrs),
              DateTime.utc_now(:microsecond)
            )
        end

      _channel ->
        Projection.upsert_channel(
          repo,
          channel_fact(chat_id, group.id, attrs),
          DateTime.utc_now(:microsecond)
        )
    end
  end

  defp channel_fact(chat_id, principal_group_id, attrs) do
    %{
      signal_channel_id: Inbound.signal_channel_id(chat_id),
      channel_kind: :im_group,
      reply_mode: :entry,
      channel_name: optional_text(attrs, "name"),
      channel_visibility: optional_text(attrs, "visibility"),
      principal_group_id: principal_group_id,
      channel_metadata:
        compact_metadata_map(%{
          "chat_id" => chat_id,
          "domain" => optional_text(attrs, "domain"),
          "app_id" => optional_text(attrs, "app_id")
        }),
      channel_raw_payload: fetch_map(attrs, "raw_payload", %{})
    }
  end

  defp log_channel_namespace_conflict(
         repo,
         signal_channel_id,
         namespace,
         existing_group_id,
         group_id
       ) do
    existing_namespace =
      ExternalBinding
      |> where([binding], binding.group_id == ^existing_group_id)
      |> where([binding], binding.external_kind == :im_group)
      |> select([binding], binding.provider)
      |> repo.one()

    Logging.warning(
      "lark_adapter.im_groups.channel_namespace_conflict",
      "lark adapter skipped IM group channel FK update because another namespace owns it",
      %{
        signal_channel_id: signal_channel_id,
        namespace: namespace,
        existing_namespace: existing_namespace,
        existing_group_id: existing_group_id,
        group_id: group_id
      }
    )
  end

  defp mark_missing_chats_left(%AdapterContext{} = context, config, observed_chat_ids) do
    observed = MapSet.new(observed_chat_ids)
    namespace = namespace(config)

    groups =
      ExternalBinding
      |> join(:inner, [binding], group in Group, on: group.id == binding.group_id)
      |> where(
        [binding, group],
        binding.provider == ^namespace and binding.external_kind == :im_group and
          group.domain == :im_group
      )
      |> select([binding, group], {binding.external_id, group.id, group.metadata})
      |> Repo.all()

    groups
    |> Enum.reject(fn {chat_id, _group_id, _metadata} -> MapSet.member?(observed, chat_id) end)
    |> Enum.filter(fn {_chat_id, _group_id, metadata} ->
      BindingMembership.joined?(metadata, context)
    end)
    |> Enum.reduce_while({:ok, 0}, fn {chat_id, _group_id, _metadata}, {:ok, count} ->
      case mark_participant_left(namespace, chat_id, context) do
        {:ok, _result} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp mark_participant_left(namespace, chat_id, %AdapterContext{} = context) do
    Repo.transact(fn repo ->
      with :ok <- lock_chat(repo, namespace, chat_id),
           {:ok, group} <- lock_im_group_by_binding(repo, namespace, chat_id),
           {:ok, group} <-
             group
             |> Group.changeset(%{
               metadata: BindingMembership.project(group.metadata, context, :left)
             })
             |> repo.update(),
           {:ok, cleanup} <- maybe_clear_all_left_members(repo, group) do
        {:ok, Map.put(cleanup, :group_id, group.id)}
      else
        {:error, :not_found} -> {:ok, %{status: :ignored_missing_group}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp mark_all_participants_left(namespace, chat_id) do
    Repo.transact(fn repo ->
      with :ok <- lock_chat(repo, namespace, chat_id),
           {:ok, group} <- lock_im_group_by_binding(repo, namespace, chat_id),
           metadata <- BindingMembership.mark_all_left(group.metadata),
           {:ok, group} <- group |> Group.changeset(%{metadata: metadata}) |> repo.update(),
           {:ok, cleanup} <- maybe_clear_all_left_members(repo, group) do
        {:ok, Map.put(cleanup, :group_id, group.id)}
      else
        {:error, :not_found} -> {:ok, %{status: :ignored_missing_group}}
        {:error, _reason} = error -> error
      end
    end)
  end

  defp maybe_clear_all_left_members(repo, %Group{} = group) do
    if BindingMembership.all_left?(group.metadata) do
      AuthZStore.clear_static_group_members(repo, group.id, :im_group)
      |> case do
        {:ok, result} -> {:ok, Map.put(result, :status, :all_left_members_cleared)}
        {:error, _reason} = error -> error
      end
    else
      {:ok, %{status: :participant_marked_left, removed_memberships: 0}}
    end
  end

  defp group_name(namespace, chat_id), do: "#{namespace}:im_group:#{String.downcase(chat_id)}"

  defp group_display_name(attrs, chat_id) do
    optional_text(attrs, "name") || "Lark IM Group #{chat_id}"
  end

  defp maybe_put_display_name(changes, attrs, _chat_id) do
    case optional_text(attrs, "name") do
      name when is_binary(name) -> Map.put(changes, :display_name, name)
      nil -> changes
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

  defp fetch_im_group(namespace, chat_id) do
    case get_im_group_by_binding(Repo, namespace, chat_id) do
      {:ok, group} -> {:ok, group}
      {:error, _reason} = error -> error
    end
  end

  defp remove_member_from_group(context, config, chat_id, user_id) do
    case fetch_im_group(namespace(config), chat_id) do
      {:ok, group} ->
        remove_member_from_existing_group(context, config, chat_id, group, user_id)

      {:error, :not_found} ->
        enqueue_chat_refresh(context, config, chat_id, reason: "member_removed_missing_group")
        |> enqueue_result(:refresh_enqueued)
    end
  end

  defp remove_member_from_existing_group(context, config, chat_id, group, user_id) do
    with {:ok, principal_uid} <-
           Principals.resolve_platform_subject_uid(namespace(config), user_id) do
      case AuthZ.remove_principal_from_group(principal_uid, group.id) do
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
    with {:ok, user_id} <- member_user_id(member) do
      Principals.upsert_platform_subject_human(%{
        provider: namespace(config),
        external_id: user_id,
        uid: user_id,
        display_name: member_display_name(member),
        metadata:
          compact_metadata_map(%{
            "open_id" => member_open_id(member),
            "union_id" => optional_text(member, "union_id"),
            "member_type" => member_type(member)
          })
      })
    end
  end

  defp member_payload(content, user_id) do
    content
    |> fetch_map("member", content)
    |> Map.put_new("user_id", user_id)
  end

  defp member_user_id(map) when is_map(map) do
    value =
      optional_text(map, "user_id") ||
        get_in(fetch_map(map, "member_id", %{}), ["user_id"]) ||
        get_in(fetch_map(map, "member", %{}), ["user_id"]) ||
        get_in(fetch_map(fetch_map(map, "member", %{}), "member_id", %{}), ["user_id"])

    case value do
      user_id when is_binary(user_id) -> {:ok, user_id}
      nil -> {:error, :missing_user_id}
    end
  end

  defp member_user_id(_map), do: {:error, :missing_user_id}

  defp member_open_id(member) do
    optional_text(member, "open_id") ||
      get_in(fetch_map(member, "member_id", %{}), ["open_id"])
  end

  defp member_display_name(member) do
    optional_text(member, "name") ||
      optional_text(member, "member_name") ||
      optional_text(member, "display_name") ||
      optional_text(member, "user_id")
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

  defp namespace(config), do: Map.get(config, "platformSubjectNamespace", "lark-main")

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

  defp lock_chat(repo, namespace, chat_id) do
    SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [
      "lark_im_group:#{namespace}:#{chat_id}"
    ])

    :ok
  end
end
