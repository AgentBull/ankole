defmodule Ankole.Plugins.Microsoft365Adapter.TeamsChannels do
  @moduledoc """
  Teams conversation projection into gateway channels and AuthZ groups.

  Teams offers no "list every conversation this bot can see" API, so the
  projection universe is the set of already-mirrored conversations: a team is
  known once any of its channels produced an activity (installation
  conversationUpdate or message), and only those teams can be enumerated with
  the connector's channel-list call. Standard channel membership in Teams is
  team membership, which `pagedmembers` reports per conversation.

  Mirrors are sharded by bot app: writes stamp `app_id` into the channel
  metadata, and sync enumeration only visits mirrors stamped with the current
  binding's app.
  """

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.{AuthZ, Logging, Principals, Repo, SignalsGateway}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.Microsoft365Adapter.{Config, Conversations}

  alias Ankole.SignalsGateway.{
    AdapterContext,
    Binding,
    BindingMembership,
    Channel,
    Projection
  }

  alias MicrosoftOpenAPI.BotConnector

  @spec handle_binding_saved(Binding.t(), map()) :: :ok | {:error, term()}
  def handle_binding_saved(%Binding{agent_uid: agent_uid, name: binding_name}, _config) do
    case enqueue_binding_full_sync(agent_uid, binding_name,
           reason: "binding_saved",
           source: "signal_binding"
         ) do
      {:ok, _job} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec enqueue_full_syncs(keyword()) :: {:ok, map()} | {:error, term()}
  def enqueue_full_syncs(opts \\ []) do
    SignalsGateway.list_enabled_bindings("teams", Keyword.take(opts, [:repo]))
    |> Enum.reduce_while({:ok, %{enqueued: [], skipped: []}}, fn binding, {:ok, acc} ->
      case enqueue_binding_full_sync(binding.agent_uid, binding.name,
             reason: Keyword.get(opts, :reason, "startup"),
             source: Keyword.get(opts, :source, "startup")
           ) do
        {:ok, %Oban.Job{conflict?: true}} ->
          {:cont, {:ok, %{acc | skipped: [{binding.agent_uid, binding.name} | acc.skipped]}}}

        {:ok, %Oban.Job{} = job} ->
          {:cont, {:ok, %{acc | enqueued: [job | acc.enqueued]}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @spec enqueue_binding_full_sync(String.t(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_binding_full_sync(agent_uid, binding_name, opts \\ []) do
    %{
      "agent_uid" => String.downcase(agent_uid),
      "binding_name" => binding_name,
      "reason" => to_string(Keyword.get(opts, :reason, "manual")),
      "source" => to_string(Keyword.get(opts, :source, "manual"))
    }
    |> Ankole.Plugins.Microsoft365Adapter.Jobs.SyncChannels.new()
    |> Oban.insert()
  end

  @spec enqueue_conversation_refresh(AdapterContext.t(), map(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_conversation_refresh(
        %AdapterContext{} = context,
        _config,
        conversation_id,
        opts \\ []
      ) do
    %{
      "agent_uid" => String.downcase(context.agent_uid),
      "binding_name" => context.binding_name,
      "conversation_id" => conversation_id,
      "reason" => to_string(Keyword.get(opts, :reason, "event"))
    }
    |> Ankole.Plugins.Microsoft365Adapter.Jobs.RefreshChannel.new()
    |> Oban.insert()
  end

  @spec sync_binding(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def sync_binding(agent_uid, binding_name) do
    with {:ok, binding} <- SignalsGateway.get_binding(agent_uid, binding_name),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref),
         context <- binding_context(binding, config),
         {:ok, team_channels} <- sync_mirrored_teams(context, config),
         {:ok, group_chats} <- sync_mirrored_group_chats(context, config) do
      {:ok,
       %{
         binding: %{agent_uid: binding.agent_uid, binding_name: binding.name},
         synced_team_channels: team_channels,
         synced_group_chats: group_chats
       }}
    end
  end

  @spec refresh_conversation(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def refresh_conversation(agent_uid, binding_name, conversation_id) do
    with {:ok, binding} <- SignalsGateway.get_binding(agent_uid, binding_name),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref),
         context <- binding_context(binding, config),
         {:ok, mirror} <- mirrored_conversation(conversation_id),
         {:ok, result} <- sync_conversation(context, config, mirror) do
      {:ok, result}
    end
  end

  @doc """
  Applies one Teams `conversationUpdate` / `installationUpdate` activity.
  """
  @spec handle_conversation_update(map(), map()) :: {:ok, map()} | {:error, term()}
  def handle_conversation_update(consumer, activity) do
    event_type = get_in(activity, ["channelData", "eventType"])
    conversation_id = conversation_id(activity)

    cond do
      is_nil(conversation_id) ->
        {:ok, %{status: :ignored_missing_conversation}}

      bot_added?(consumer, activity) ->
        upsert_conversation_mirror(consumer.config, activity)
        enqueue_refresh_result(consumer, conversation_id, "bot_added")

      bot_removed?(consumer, activity) ->
        mark_participant_left(consumer.config, conversation_id, consumer.context)

      event_type in ["channelCreated", "channelRenamed"] ->
        upsert_event_channel_mirror(consumer.config, activity)
        {:ok, %{status: :channel_mirror_updated}}

      event_type == "channelDeleted" ->
        mark_all_participants_left(consumer.config, event_channel_id(activity) || conversation_id)

      event_type in ["teamDeleted", "teamArchived"] ->
        mark_team_channels_left(consumer.config, team_id(activity))

      members_changed?(activity) ->
        upsert_conversation_mirror(consumer.config, activity)
        enqueue_refresh_result(consumer, conversation_id, "members_changed")

      true ->
        {:ok, %{status: :ignored_unknown_conversation_event}}
    end
  end

  defp members_changed?(activity) do
    MapHelpers.fetch_list(activity, "membersAdded") != [] or
      MapHelpers.fetch_list(activity, "membersRemoved") != []
  end

  defp bot_added?(consumer, activity),
    do: bot_membership_change?(consumer, activity, "membersAdded")

  defp bot_removed?(consumer, activity),
    do: bot_membership_change?(consumer, activity, "membersRemoved")

  defp bot_membership_change?(_consumer, activity, key) do
    recipient_id =
      activity |> MapHelpers.fetch_map("recipient", %{}) |> MapHelpers.optional_text("id")

    is_binary(recipient_id) and
      activity
      |> MapHelpers.fetch_list(key)
      |> Enum.any?(&(MapHelpers.optional_text(&1, "id") == recipient_id))
  end

  # One stale team mirror (for example a deleted team) must not park the whole
  # full sync, so every team is attempted and failures are aggregated into one
  # loud error return.
  defp sync_mirrored_teams(context, config) do
    client = Config.chat_client(config)

    {synced, failures} =
      mirrored_teams(config)
      |> Enum.reduce({0, []}, fn {team_id, service_url}, {synced, failures} ->
        case sync_team(context, config, client, team_id, service_url) do
          {:ok, count} -> {synced + count, failures}
          {:error, reason} -> {synced, [%{team_id: team_id, reason: reason} | failures]}
        end
      end)

    case failures do
      [] -> {:ok, synced}
      failures -> {:error, {:team_sync_failed, Enum.reverse(failures)}}
    end
  end

  defp sync_team(context, config, client, team_id, service_url) do
    with {:ok, %{"conversations" => channels}} <-
           BotConnector.list_team_channels(client, service_url, team_id) do
      channels
      |> Enum.reduce_while({:ok, 0}, fn channel, {:ok, count} ->
        conversation_id = MapHelpers.optional_text(channel, "id")

        mirror = %{
          conversation_id: conversation_id,
          conversation_type: "channel",
          service_url: service_url,
          team_id: team_id,
          app_id: config["appID"],
          name: MapHelpers.optional_text(channel, "name")
        }

        case sync_conversation(context, config, mirror) do
          {:ok, _result} -> {:cont, {:ok, count + 1}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp sync_mirrored_group_chats(context, config) do
    mirrored_group_chats(config)
    |> Enum.reduce_while({:ok, 0}, fn mirror, {:ok, count} ->
      case sync_conversation(context, config, mirror) do
        {:ok, _result} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sync_conversation(_context, _config, %{conversation_id: nil}),
    do: {:error, :missing_conversation_id}

  defp sync_conversation(context, config, mirror) do
    client = Config.chat_client(config)

    with_conversation_lock(Config.namespace(config), mirror.conversation_id, fn ->
      with {:ok, group} <- ensure_conversation_group(context, config, mirror),
           {:ok, members} <- list_members(client, mirror),
           {:ok, uids} <- member_principal_uids(config, members),
           {:ok, replace} <- AuthZ.replace_static_group_members(group.id, :im_group, uids) do
        {:ok,
         %{
           conversation_id: mirror.conversation_id,
           group_id: group.id,
           synced_members: length(uids),
           removed_memberships: replace.removed_memberships
         }}
      end
    end)
  end

  defp list_members(client, mirror) do
    BotConnector.stream_paged_members(client, mirror.service_url, mirror.conversation_id)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, member}, {:ok, acc} -> {:cont, {:ok, [member | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, members} -> {:ok, Enum.reverse(members)}
      error -> error
    end
  end

  defp member_principal_uids(config, members) do
    members
    |> Enum.reject(&bot_member?/1)
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, acc} ->
      case upsert_member(config, member) do
        {:ok, observed} -> {:cont, {:ok, [observed.principal.uid | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, uids} -> {:ok, uids |> Enum.uniq() |> Enum.sort()}
      error -> error
    end
  end

  defp bot_member?(member) do
    id = MapHelpers.optional_text(member, "id") || ""

    String.starts_with?(id, "28:") or
      (is_nil(MapHelpers.optional_text(member, "aadObjectId")) and
         MapHelpers.optional_text(member, "userRole") == "bot")
  end

  defp upsert_member(config, member) do
    case MapHelpers.optional_text(member, "aadObjectId") || MapHelpers.optional_text(member, "id") do
      nil ->
        {:error, :missing_member_id}

      external_id ->
        Principals.upsert_platform_subject_human(
          %{
            provider: Config.namespace(config),
            external_id: external_id,
            display_name: MapHelpers.optional_text(member, "name"),
            email:
              MapHelpers.optional_text(member, "email") ||
                MapHelpers.optional_text(member, "userPrincipalName")
          }
          |> MapHelpers.compact_map()
        )
    end
  end

  defp ensure_conversation_group(context, config, mirror) do
    base_conversation_id = Conversations.base_conversation_id(mirror.conversation_id)
    provider = Config.namespace(config)

    group_result =
      case AuthZ.external_group_ids(provider, :im_group, base_conversation_id) do
        [group_id | _rest] ->
          AuthZ.get_principal_group(group_id)

        [] ->
          AuthZ.create_principal_group(%{
            name: "#{provider}:im_group:#{String.downcase(base_conversation_id)}",
            display_name: mirror[:name] || "Teams Conversation #{base_conversation_id}",
            domain: :im_group,
            kind: :static,
            metadata: BindingMembership.project(%{}, context, :joined)
          })
      end

    with {:ok, group} <- group_result,
         {:ok, group} <- maybe_update_group(group, context, mirror),
         {:ok, _binding} <-
           AuthZ.upsert_external_binding(%{
             provider: provider,
             external_kind: :im_group,
             external_id: base_conversation_id,
             group_id: group.id,
             metadata: %{
               "provider" => provider,
               "externalKind" => "im_group",
               "externalID" => base_conversation_id,
               "name" => mirror[:name]
             }
           }),
         {:ok, _projection} <- upsert_channel_projection(mirror, group.id) do
      {:ok, group}
    end
  end

  defp maybe_update_group(group, context, mirror) do
    attrs = %{metadata: BindingMembership.project(group.metadata, context, :joined)}

    attrs =
      if is_binary(mirror[:name]),
        do: Map.put(attrs, :display_name, mirror[:name]),
        else: attrs

    AuthZ.update_principal_group(group, attrs)
  end

  @doc false
  @spec upsert_channel_projection(map(), String.t() | nil) :: {:ok, term()} | {:error, term()}
  def upsert_channel_projection(mirror, group_id) do
    base_conversation_id = Conversations.base_conversation_id(mirror.conversation_id)

    fact = %{
      signal_channel_id: Conversations.signal_channel_id(base_conversation_id),
      channel_kind: if(mirror.conversation_type == "personal", do: :im_dm, else: :im_group),
      reply_mode: :entry,
      channel_name: mirror[:name],
      channel_visibility:
        if(mirror.conversation_type in ["personal", "groupChat"], do: "private"),
      principal_group_id: group_id,
      channel_metadata:
        MapHelpers.compact_metadata_map(%{
          "conversation_id" => base_conversation_id,
          "conversation_type" => mirror.conversation_type,
          "service_url" => mirror.service_url,
          "team_id" => mirror[:team_id],
          "tenant_id" => mirror[:tenant_id],
          "app_id" => mirror[:app_id]
        }),
      channel_raw_payload: mirror[:raw] || %{}
    }

    Repo.transact(fn repo ->
      Projection.upsert_channel(repo, fact, DateTime.utc_now(:microsecond))
    end)
  end

  defp upsert_conversation_mirror(config, activity) do
    conversation_id = conversation_id(activity)

    mirror = %{
      conversation_id: conversation_id,
      conversation_type:
        activity
        |> MapHelpers.fetch_map("conversation", %{})
        |> MapHelpers.optional_text("conversationType") || "channel",
      service_url: MapHelpers.optional_text(activity, "serviceUrl"),
      team_id: team_id(activity),
      tenant_id: get_in(activity, ["channelData", "tenant", "id"]),
      app_id: config["appID"],
      name:
        activity |> MapHelpers.fetch_map("conversation", %{}) |> MapHelpers.optional_text("name"),
      raw: MapHelpers.fetch_map(activity, "conversation", %{})
    }

    case upsert_channel_projection(mirror, nil) do
      {:ok, _channel} ->
        :ok

      {:error, reason} ->
        Logging.warning(
          "microsoft365_adapter.teams_channels.mirror_upsert_failed",
          "Teams conversation mirror upsert failed",
          %{conversation_id: conversation_id, reason: inspect(reason)}
        )

        :ok
    end
  end

  defp upsert_event_channel_mirror(config, activity) do
    channel = get_in(activity, ["channelData", "channel"]) || %{}

    case MapHelpers.optional_text(channel, "id") do
      nil ->
        :ok

      channel_id ->
        mirror = %{
          conversation_id: channel_id,
          conversation_type: "channel",
          service_url: MapHelpers.optional_text(activity, "serviceUrl"),
          team_id: team_id(activity),
          tenant_id: get_in(activity, ["channelData", "tenant", "id"]),
          app_id: config["appID"],
          name: MapHelpers.optional_text(channel, "name"),
          raw: channel
        }

        case upsert_channel_projection(mirror, nil) do
          {:ok, _channel} -> :ok
          {:error, _reason} -> :ok
        end
    end
  end

  defp mirrored_conversation(conversation_id) do
    signal_channel_id =
      conversation_id |> Conversations.base_conversation_id() |> Conversations.signal_channel_id()

    case Repo.get(Channel, signal_channel_id) do
      %Channel{} = channel ->
        metadata = channel.metadata || %{}

        case MapHelpers.optional_text(metadata, "service_url") do
          nil ->
            {:error, :missing_service_url}

          service_url ->
            {:ok,
             %{
               conversation_id:
                 MapHelpers.optional_text(metadata, "conversation_id") ||
                   Conversations.base_conversation_id(conversation_id),
               conversation_type:
                 MapHelpers.optional_text(metadata, "conversation_type") || "channel",
               service_url: service_url,
               team_id: MapHelpers.optional_text(metadata, "team_id"),
               name: channel.name
             }}
        end

      nil ->
        {:error, :missing_channel_mirror}
    end
  end

  defp mirrored_teams(config) do
    Channel
    |> where([channel], like(channel.id, "teams:%"))
    |> select([channel], channel.metadata)
    |> Repo.all()
    |> Enum.flat_map(fn metadata ->
      metadata = metadata || %{}
      team_id = MapHelpers.optional_text(metadata, "team_id")
      service_url = MapHelpers.optional_text(metadata, "service_url")

      if mirror_visible_to_app?(metadata, config) and is_binary(team_id) and
           is_binary(service_url),
         do: [{team_id, service_url}],
         else: []
    end)
    |> Enum.uniq()
  end

  defp mirrored_group_chats(config) do
    Channel
    |> where([channel], like(channel.id, "teams:%"))
    |> select([channel], {channel.name, channel.metadata})
    |> Repo.all()
    |> Enum.flat_map(fn {name, metadata} ->
      metadata = metadata || %{}

      with true <- mirror_visible_to_app?(metadata, config),
           "groupChat" <- MapHelpers.optional_text(metadata, "conversation_type"),
           conversation_id when is_binary(conversation_id) <-
             MapHelpers.optional_text(metadata, "conversation_id"),
           service_url when is_binary(service_url) <-
             MapHelpers.optional_text(metadata, "service_url") do
        [
          %{
            conversation_id: conversation_id,
            conversation_type: "groupChat",
            service_url: service_url,
            team_id: nil,
            name: name
          }
        ]
      else
        _other -> []
      end
    end)
  end

  defp mirror_visible_to_app?(metadata, config),
    do: MapHelpers.optional_text(metadata, "app_id") == config["appID"]

  defp mark_team_channels_left(_config, nil), do: {:ok, %{status: :ignored_missing_team}}

  defp mark_team_channels_left(config, team_id) do
    Channel
    |> where([channel], like(channel.id, "teams:%"))
    |> select([channel], channel.metadata)
    |> Repo.all()
    |> Enum.filter(fn metadata ->
      metadata = metadata || %{}

      mirror_visible_to_app?(metadata, config) and
        MapHelpers.optional_text(metadata, "team_id") == team_id
    end)
    |> Enum.reduce_while({:ok, 0}, fn metadata, {:ok, count} ->
      case MapHelpers.optional_text(metadata, "conversation_id") do
        nil ->
          {:cont, {:ok, count}}

        conversation_id ->
          case mark_all_participants_left(config, conversation_id) do
            {:ok, _result} -> {:cont, {:ok, count + 1}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, count} -> {:ok, %{status: :team_channels_left, cleared: count}}
      error -> error
    end
  end

  defp mark_participant_left(config, conversation_id, %AdapterContext{} = context) do
    base_conversation_id = Conversations.base_conversation_id(conversation_id)
    provider = Config.namespace(config)

    with_conversation_lock(provider, base_conversation_id, fn ->
      case fetch_group(provider, base_conversation_id) do
        {:ok, group} ->
          metadata = BindingMembership.project(group.metadata, context, :left)

          with {:ok, group} <- AuthZ.update_principal_group(group, %{metadata: metadata}) do
            if BindingMembership.all_left?(metadata) do
              with {:ok, result} <- AuthZ.replace_static_group_members(group.id, :im_group, []) do
                {:ok,
                 %{
                   status: :all_participants_left,
                   group_id: group.id,
                   removed_memberships: result.removed_memberships
                 }}
              end
            else
              {:ok, %{status: :participant_marked_left, group_id: group.id}}
            end
          end

        {:error, :not_found} ->
          {:ok, %{status: :ignored_missing_group}}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp mark_all_participants_left(config, conversation_id) do
    base_conversation_id = Conversations.base_conversation_id(conversation_id)
    provider = Config.namespace(config)

    with_conversation_lock(provider, base_conversation_id, fn ->
      case fetch_group(provider, base_conversation_id) do
        {:ok, group} ->
          metadata = BindingMembership.mark_all_left(group.metadata)

          with {:ok, group} <- AuthZ.update_principal_group(group, %{metadata: metadata}),
               {:ok, result} <- AuthZ.replace_static_group_members(group.id, :im_group, []) do
            {:ok,
             %{
               status: :conversation_gone,
               group_id: group.id,
               removed_memberships: result.removed_memberships
             }}
          end

        {:error, :not_found} ->
          {:ok, %{status: :ignored_missing_group}}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp fetch_group(provider, base_conversation_id) do
    case AuthZ.external_group_ids(provider, :im_group, base_conversation_id) do
      [id | _rest] -> AuthZ.get_principal_group(id)
      [] -> {:error, :not_found}
    end
  end

  defp with_conversation_lock(provider, conversation_id, fun) when is_binary(conversation_id) do
    Repo.transact(fn repo ->
      SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [
        "teams_conversation:#{provider}:#{conversation_id}"
      ])

      fun.()
    end)
  end

  defp with_conversation_lock(_provider, _conversation_id, _fun),
    do: {:error, :missing_conversation_id}

  defp enqueue_refresh_result(consumer, conversation_id, reason) do
    case enqueue_conversation_refresh(consumer.context, consumer.config, conversation_id,
           reason: reason
         ) do
      {:ok, %Oban.Job{} = job} -> {:ok, %{status: :refresh_enqueued, job_id: job.id}}
      {:error, _reason} = error -> error
    end
  end

  defp binding_context(binding, config) do
    AdapterContext.new(
      agent_uid: binding.agent_uid,
      binding_name: binding.name,
      adapter: binding.adapter,
      user_name: Map.get(config, "userName", "Teams")
    )
  end

  defp conversation_id(activity) do
    activity |> MapHelpers.fetch_map("conversation", %{}) |> MapHelpers.optional_text("id")
  end

  defp event_channel_id(activity) do
    get_in(activity, ["channelData", "channel", "id"])
  end

  defp team_id(activity), do: get_in(activity, ["channelData", "team", "id"])
end
