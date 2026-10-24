defmodule Ankole.Plugins.SlackAdapter.Channels do
  @moduledoc false

  alias Ankole.Signals.Bindings
  alias Ankole.{Logging, Principals}
  alias Ankole.AuthZ
  alias Ankole.Plugins.ChannelSync
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.SlackAdapter.Config
  alias Ankole.Plugins.SlackAdapter.ConnectionReconciler
  alias Ankole.Plugins.SlackAdapter.Inbound

  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.Binding
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.IMGroupMembers
  alias Ankole.Conversations.IMGroupProjection

  alias SlackOpenAPI.{Event, Pagination}

  @spec handle_binding_saved(Binding.t(), map()) :: :ok | {:error, term()}
  def handle_binding_saved(%Binding{agent_uid: agent_uid, name: binding_name}, _config) do
    case ChannelSync.enqueue_binding(
           Ankole.Plugins.SlackAdapter.Jobs.SyncChannels,
           agent_uid,
           binding_name,
           reason: "binding_saved",
           source: "signal_binding"
         ) do
      {:ok, _job} -> ConnectionReconciler.reconcile_async()
      {:error, _reason} = error -> error
    end
  end

  @spec enqueue_channel_refresh(AdapterContext.t(), map(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  defp enqueue_channel_refresh(%AdapterContext{} = context, _config, channel_id, opts) do
    %{
      "agent_uid" => String.downcase(context.agent_uid),
      "binding_name" => context.binding_name,
      "channel_id" => channel_id,
      "reason" => to_string(Keyword.get(opts, :reason, "event"))
    }
    |> Ankole.Plugins.SlackAdapter.Jobs.RefreshChannel.new()
    |> Oban.insert()
  end

  @spec maybe_enqueue_missing_channel_refresh(map(), map()) :: :ok
  def maybe_enqueue_missing_channel_refresh(%{context: context, config: config}, %{
        channel: %{kind: :im_group},
        provider_conversation_id: provider_conversation_id
      }) do
    case Ankole.Conversations.External.get_conversation(provider_conversation_id) do
      %Conversation{principal_group_id: group_id} when is_binary(group_id) ->
        :ok

      %Conversation{} ->
        case channel_id_from_signal(provider_conversation_id) do
          nil ->
            :ok

          channel_id ->
            enqueue_refresh_safely(context, config, channel_id, "missing_channel_principal_group")
        end

      nil ->
        :ok
    end
  end

  def maybe_enqueue_missing_channel_refresh(_consumer, _input), do: :ok

  @spec sync_binding(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def sync_binding(agent_uid, binding_name) do
    with {:ok, binding} <- Ankole.Signals.Bindings.get_binding(agent_uid, binding_name),
         {:ok, config} <- Bindings.binding_config(binding, Config),
         {:ok, channels} <- list_channels(config),
         {:ok, bot_ids} <- list_bot_ids(config),
         context <- binding_context(binding, config),
         {:ok, count} <- sync_channels(context, config, channels, bot_ids),
         {:ok, marked_left} <-
           IMGroupProjection.mark_missing_left(
             namespace(config),
             Enum.map(channels, & &1["id"]),
             context
           ) do
      {:ok,
       %{
         binding: %{agent_uid: binding.agent_uid, binding_name: binding.name},
         synced_channels: count,
         marked_left: marked_left
       }}
    end
  end

  @spec refresh_channel(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_channel(agent_uid, binding_name, channel_id) do
    with {:ok, binding} <- Ankole.Signals.Bindings.get_binding(agent_uid, binding_name),
         {:ok, config} <- Bindings.binding_config(binding, Config),
         context <- binding_context(binding, config),
         {:ok, channel} <- fetch_channel(config, channel_id),
         {:ok, bot_ids} <- list_bot_ids(config),
         {:ok, group} <-
           IMGroupProjection.ensure_group(
             namespace(config),
             channel_id,
             %{"name" => channel["name"]},
             context,
             group_projection_options(config, channel)
           ),
         {:ok, members} <- list_members(config, channel_id),
         {:ok, principal_uids} <- member_principal_uids(config, members, bot_ids),
         {:ok, replace} <- IMGroupMembers.replace_members(group.id, principal_uids) do
      {:ok,
       %{
         channel_id: channel_id,
         group_id: group.id,
         synced_members: length(principal_uids),
         removed_memberships: replace.removed_memberships
       }}
    end
  end

  @spec handle_im_event(String.t(), Event.t(), [map()]) :: {:ok, list()} | {:error, term()}
  def handle_im_event(event_type, %Event{} = event, consumers) do
    consumers
    |> Enum.filter(&match?(%{kind: :chat}, &1))
    |> Enum.map(&handle_event(&1, event_type, event))
    |> MapHelpers.collect_results()
  end

  defp handle_event(consumer, "member_joined_channel", event) do
    content = event.content || %{}
    channel_id = Map.get(content, "channel")
    user_id = Map.get(content, "user")

    if user_id == runtime_bot_user_id(consumer.config) do
      enqueue_refresh_result(consumer, channel_id, "bot_joined")
    else
      with {:ok, group} <- IMGroupProjection.get_group(namespace(consumer.config), channel_id),
           {:ok, observed} <- upsert_member(consumer.config, user_id),
           {:ok, _membership} <-
             AuthZ.add_synced_group_member(group.id, :im_group, observed.principal.uid) do
        {:ok, %{status: :member_added, group_id: group.id, principal_uid: observed.principal.uid}}
      else
        {:error, :not_found} ->
          enqueue_refresh_result(consumer, channel_id, "member_added_missing_group")

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp handle_event(consumer, "member_left_channel", event) do
    content = event.content || %{}
    channel_id = Map.get(content, "channel")
    user_id = Map.get(content, "user")

    if user_id == runtime_bot_user_id(consumer.config) do
      IMGroupProjection.mark_left(namespace(consumer.config), channel_id, consumer.context)
      |> left_result(:all_participants_left)
    else
      with {:ok, group} <- IMGroupProjection.get_group(namespace(consumer.config), channel_id),
           {:ok, principal_uid} <-
             Principals.resolve_platform_subject_uid(namespace(consumer.config), user_id) do
        case AuthZ.remove_synced_group_member(group.id, :im_group, principal_uid) do
          {:ok, :deleted} -> {:ok, %{status: :member_removed}}
          {:error, :not_found} -> {:ok, %{status: :member_already_removed}}
          {:error, _reason} = error -> error
        end
      else
        {:error, :not_found} -> {:ok, %{status: :ignored_unknown_member_or_channel}}
        {:error, _reason} = error -> error
      end
    end
  end

  defp handle_event(consumer, event_type, event)
       when event_type in ["channel_rename", "group_rename"] do
    channel_id = get_in(event.content || %{}, ["channel", "id"])
    enqueue_refresh_result(consumer, channel_id, "channel_renamed")
  end

  defp handle_event(consumer, event_type, event)
       when event_type in ["channel_deleted", "channel_archive"] do
    channel_id = Map.get(event.content || %{}, "channel")

    IMGroupProjection.mark_all_left(namespace(consumer.config), channel_id)
    |> left_result(:channel_gone)
  end

  defp handle_event(_consumer, _event_type, _event),
    do: {:ok, %{status: :ignored_unknown_channel_event}}

  defp sync_channels(context, config, channels, bot_ids) do
    channels
    |> Enum.reject(&Map.get(&1, "is_im", false))
    |> Enum.reduce_while({:ok, 0}, fn channel, {:ok, count} ->
      result =
        with {:ok, group} <-
               IMGroupProjection.ensure_group(
                 namespace(config),
                 channel["id"],
                 %{"name" => channel["name"]},
                 context,
                 group_projection_options(config, channel)
               ),
             {:ok, members} <- list_members(config, channel["id"]),
             {:ok, uids} <- member_principal_uids(config, members, bot_ids),
             {:ok, _result} <- IMGroupMembers.replace_members(group.id, uids) do
          {:ok, group}
        end

      case result do
        {:ok, _group} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp list_channels(config) do
    client = Config.client(config)

    Pagination.stream(client, "users.conversations",
      query: [types: "public_channel,private_channel,mpim,im", exclude_archived: true, limit: 200],
      items: ["channels"]
    )
    |> collect_items()
  end

  defp fetch_channel(config, channel_id) do
    client = Config.client(config)

    case SlackOpenAPI.get(client, "conversations.info", query: [channel: channel_id]) do
      {:ok, %{"channel" => channel}} -> {:ok, channel}
      {:ok, body} -> {:error, {:unexpected_channel_info, body}}
      {:error, _reason} = error -> error
    end
  end

  defp list_bot_ids(config) do
    client = Config.client(config)

    Pagination.stream(client, "users.list", query: [limit: 200], items: ["members"])
    |> collect_items()
    |> case do
      {:ok, users} ->
        {:ok,
         users
         |> Enum.filter(&(Map.get(&1, "is_bot") == true or Map.get(&1, "id") == "USLACKBOT"))
         |> Enum.map(& &1["id"])
         |> Enum.reject(&is_nil/1)
         |> MapSet.new()}

      {:error, _reason} = error ->
        error
    end
  end

  defp list_members(config, channel_id) do
    client = Config.client(config)

    Pagination.stream(client, "conversations.members",
      query: [channel: channel_id, limit: 200],
      items: ["members"]
    )
    |> collect_items()
  end

  defp collect_items(stream) do
    Enum.reduce_while(stream, {:ok, []}, fn
      {:ok, item}, {:ok, acc} -> {:cont, {:ok, [item | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp left_result({:ok, %{status: :all_left_members_cleared} = result}, status),
    do: {:ok, %{result | status: status}}

  defp left_result({:ok, %{status: :participant_marked_left} = result}, _status),
    do: {:ok, Map.drop(result, [:removed_memberships])}

  defp left_result(result, _status), do: result

  defp group_projection_options(config, channel) do
    provider = namespace(config)

    [
      default_display_name: "Slack Channel #{channel["id"]}",
      binding_metadata: %{
        "provider" => provider,
        "externalKind" => "im_group",
        "externalID" => channel["id"],
        "name" => channel["name"]
      },
      channel: %{
        on_conflict: :replace,
        fact: %{
          provider_conversation_id: Inbound.provider_conversation_id(channel["id"]),
          channel_kind: if(channel["is_im"], do: :im_dm, else: :im_group),
          reply_mode: :entry,
          channel_name: channel["name"],
          channel_visibility: if(channel["is_private"], do: "private", else: "public"),
          channel_metadata:
            MapHelpers.compact_metadata_map(%{
              "channel_id" => channel["id"],
              "team_id" => channel["context_team_id"],
              "visibility" => if(channel["is_private"], do: "private", else: "public")
            }),
          channel_raw_payload: channel
        }
      }
    ]
  end

  defp member_principal_uids(config, members, bot_ids) do
    members
    |> Enum.reject(&(&1 == runtime_bot_user_id(config) or MapSet.member?(bot_ids, &1)))
    |> Enum.reduce_while({:ok, []}, fn user_id, {:ok, acc} ->
      case upsert_member(config, user_id) do
        {:ok, observed} -> {:cont, {:ok, [observed.principal.uid | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, uids} -> {:ok, uids |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp upsert_member(config, user_id) when is_binary(user_id) do
    Principals.upsert_platform_subject_human(%{
      provider: namespace(config),
      external_id: user_id
    })
  end

  defp upsert_member(_config, _user_id), do: {:error, :missing_user_id}

  defp enqueue_refresh_result(consumer, channel_id, reason) when is_binary(channel_id) do
    case enqueue_channel_refresh(consumer.context, consumer.config, channel_id, reason: reason) do
      {:ok, %Oban.Job{} = job} -> {:ok, %{status: :refresh_enqueued, job_id: job.id}}
      {:error, _reason} = error -> error
    end
  end

  defp enqueue_refresh_result(_consumer, _channel_id, _reason), do: {:error, :missing_channel_id}

  defp enqueue_refresh_safely(context, config, channel_id, reason) do
    case enqueue_channel_refresh(context, config, channel_id, reason: reason) do
      {:ok, _job} ->
        :ok

      {:error, error} ->
        Logging.warning(
          "slack_adapter.channels.refresh_enqueue_failed",
          "Slack channel refresh enqueue failed",
          %{channel_id: channel_id, reason: inspect(error)}
        )

        :ok
    end
  end

  defp binding_context(binding, config) do
    AdapterContext.new(
      agent_uid: binding.agent_uid,
      binding_name: binding.name,
      adapter: binding.adapter,
      user_name: Map.get(config, "userName", "Slack")
    )
  end

  defp namespace(config), do: Config.subject_namespace(config)

  defp runtime_bot_user_id(config),
    do: Map.get(config, "runtimeBotUserID") || Map.get(config, "botUserID")

  defp channel_id_from_signal("slack:" <> encoded), do: URI.decode(encoded)
  defp channel_id_from_signal(_value), do: nil
end
