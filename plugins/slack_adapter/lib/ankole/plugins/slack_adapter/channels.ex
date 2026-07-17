defmodule Ankole.Plugins.SlackAdapter.Channels do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ecto.Adapters.SQL
  alias Ankole.{AuthZ, Logging, Principals, Repo, SignalsGateway}
  alias Ankole.AuthZ.{ExternalBinding, Group, Store}
  alias Ankole.Plugins.MapHelpers
  alias Ankole.Plugins.SlackAdapter.{Config, Inbound}

  alias Ankole.SignalsGateway.{
    AdapterContext,
    Binding,
    BindingMembership,
    Channel,
    Projection
  }

  alias SlackOpenAPI.{Event, Pagination}

  @event_types [
    "member_joined_channel",
    "member_left_channel",
    "channel_rename",
    "channel_deleted",
    "channel_archive"
  ]

  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

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
    SignalsGateway.list_enabled_bindings("slack", Keyword.take(opts, [:repo]))
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
    |> Ankole.Plugins.SlackAdapter.Jobs.SyncChannels.new()
    |> Oban.insert()
  end

  @spec enqueue_channel_refresh(AdapterContext.t(), map(), String.t(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue_channel_refresh(%AdapterContext{} = context, _config, channel_id, opts \\ []) do
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
        signal_channel_id: signal_channel_id
      }) do
    case Repo.get(Channel, signal_channel_id) do
      %Channel{principal_group_id: group_id} when is_binary(group_id) ->
        :ok

      %Channel{} ->
        case channel_id_from_signal(signal_channel_id) do
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

  @spec sync_binding(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def sync_binding(agent_uid, binding_name, opts \\ []) do
    with {:ok, binding} <- SignalsGateway.get_binding(agent_uid, binding_name),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref),
         {:ok, channels} <- list_channels(config, opts),
         {:ok, bot_ids} <- list_bot_ids(config, opts),
         context <- binding_context(binding, config),
         {:ok, count} <- sync_channels(context, config, channels, bot_ids, opts),
         {:ok, marked_left} <-
           mark_missing_channels_left(context, config, Enum.map(channels, & &1["id"])) do
      {:ok,
       %{
         binding: %{agent_uid: binding.agent_uid, binding_name: binding.name},
         synced_channels: count,
         marked_left: marked_left
       }}
    end
  end

  @spec refresh_channel(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def refresh_channel(agent_uid, binding_name, channel_id, opts \\ []) do
    with {:ok, binding} <- SignalsGateway.get_binding(agent_uid, binding_name),
         {:ok, config} <- Config.load_chat_config_ref(binding.config_ref),
         context <- binding_context(binding, config),
         {:ok, channel} <- fetch_channel(config, channel_id, opts),
         {:ok, bot_ids} <- list_bot_ids(config, opts),
         {:ok, result} <-
           with_channel_lock(namespace(config), channel_id, fn ->
             with {:ok, group} <- ensure_channel_group(context, config, channel),
                  {:ok, members} <- list_members(config, channel_id, opts),
                  {:ok, principal_uids} <- member_principal_uids(config, members, bot_ids),
                  {:ok, replace} <-
                    AuthZ.replace_static_group_members(group.id, :im_group, principal_uids) do
               {:ok,
                %{
                  channel_id: channel_id,
                  group_id: group.id,
                  synced_members: length(principal_uids),
                  removed_memberships: replace.removed_memberships
                }}
             end
           end) do
      {:ok, result}
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
      with {:ok, group} <- fetch_group(namespace(consumer.config), channel_id),
           {:ok, observed} <- upsert_member(consumer.config, user_id),
           {:ok, _membership} <-
             Repo.transact(fn repo ->
               Store.add_synced_group_member(repo, group.id, :im_group, observed.principal.uid)
             end) do
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
      mark_participant_left(consumer.context, consumer.config, channel_id)
    else
      with {:ok, group} <- fetch_group(namespace(consumer.config), channel_id),
           {:ok, principal_uid} <-
             Principals.resolve_platform_subject_uid(namespace(consumer.config), user_id) do
        case Repo.transact(fn repo ->
               Store.remove_synced_group_member(repo, group.id, :im_group, principal_uid)
             end) do
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

  defp handle_event(consumer, "channel_rename", event) do
    channel_id = get_in(event.content || %{}, ["channel", "id"])
    enqueue_refresh_result(consumer, channel_id, "channel_renamed")
  end

  defp handle_event(consumer, event_type, event)
       when event_type in ["channel_deleted", "channel_archive"] do
    channel_id = Map.get(event.content || %{}, "channel")
    mark_all_participants_left(consumer.config, channel_id)
  end

  defp handle_event(_consumer, _event_type, _event),
    do: {:ok, %{status: :ignored_unknown_channel_event}}

  defp sync_channels(context, config, channels, bot_ids, opts) do
    channels
    |> Enum.reject(&Map.get(&1, "is_im", false))
    |> Enum.reduce_while({:ok, 0}, fn channel, {:ok, count} ->
      result =
        with_channel_lock(namespace(config), channel["id"], fn ->
          with {:ok, group} <- ensure_channel_group(context, config, channel),
               {:ok, members} <- list_members(config, channel["id"], opts),
               {:ok, uids} <- member_principal_uids(config, members, bot_ids),
               {:ok, _result} <-
                 AuthZ.replace_static_group_members(group.id, :im_group, uids) do
            {:ok, group}
          end
        end)

      case result do
        {:ok, _group} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp list_channels(config, opts) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))

    Pagination.stream(client, "users.conversations",
      query: [types: "public_channel,private_channel,mpim,im", exclude_archived: true, limit: 200],
      items: ["channels"]
    )
    |> collect_items()
  end

  defp fetch_channel(config, channel_id, opts) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))

    case SlackOpenAPI.get(client, "conversations.info", query: [channel: channel_id]) do
      {:ok, %{"channel" => channel}} -> {:ok, channel}
      {:ok, body} -> {:error, {:unexpected_channel_info, body}}
      {:error, _reason} = error -> error
    end
  end

  defp list_bot_ids(config, opts) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))

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

  defp list_members(config, channel_id, opts) do
    client = Config.client(config, Keyword.get(opts, :client_opts, []))

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

  defp ensure_channel_group(context, config, channel) do
    channel_id = Map.fetch!(channel, "id")
    provider = namespace(config)

    group_result =
      case AuthZ.external_group_ids(provider, :im_group, channel_id) do
        [group_id | _rest] ->
          AuthZ.get_principal_group(group_id)

        [] ->
          AuthZ.create_principal_group(%{
            name: "#{provider}:im_group:#{String.downcase(channel_id)}",
            display_name: channel["name"] || "Slack Channel #{channel_id}",
            domain: :im_group,
            kind: :static,
            metadata: participant_metadata(context)
          })
      end

    with {:ok, group} <- group_result,
         {:ok, group} <- maybe_update_group(group, context, channel),
         {:ok, _binding} <-
           AuthZ.upsert_external_binding(%{
             provider: provider,
             external_kind: :im_group,
             external_id: channel_id,
             group_id: group.id,
             metadata: %{
               "provider" => provider,
               "externalKind" => "im_group",
               "externalID" => channel_id,
               "name" => channel["name"]
             }
           }),
         {:ok, _projection} <- upsert_channel_projection(channel, group.id) do
      {:ok, group}
    end
  end

  defp maybe_update_group(group, context, channel) do
    metadata = BindingMembership.project(group.metadata, context, :joined)
    attrs = %{metadata: metadata}

    attrs =
      if is_binary(channel["name"]),
        do: Map.put(attrs, :display_name, channel["name"]),
        else: attrs

    AuthZ.update_principal_group(group, attrs)
  end

  defp participant_metadata(context), do: BindingMembership.project(%{}, context, :joined)

  defp upsert_channel_projection(channel, group_id) do
    fact = %{
      signal_channel_id: Inbound.signal_channel_id(channel["id"]),
      channel_kind: if(channel["is_im"], do: :im_dm, else: :im_group),
      reply_mode: :entry,
      channel_name: channel["name"],
      channel_visibility: if(channel["is_private"], do: "private", else: "public"),
      principal_group_id: group_id,
      channel_metadata:
        MapHelpers.compact_metadata_map(%{
          "channel_id" => channel["id"],
          "team_id" => channel["context_team_id"],
          "visibility" => if(channel["is_private"], do: "private", else: "public")
        }),
      channel_raw_payload: channel
    }

    Repo.transact(fn repo ->
      Projection.upsert_channel(repo, fact, DateTime.utc_now(:microsecond))
    end)
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
      external_id: user_id,
      uid: user_id
    })
  end

  defp upsert_member(_config, _user_id), do: {:error, :missing_user_id}

  defp fetch_group(provider, channel_id) do
    case AuthZ.external_group_ids(provider, :im_group, channel_id) do
      [id | _rest] -> AuthZ.get_principal_group(id)
      [] -> {:error, :not_found}
    end
  end

  defp mark_participant_left(context, config, channel_id) do
    with_channel_lock(namespace(config), channel_id, fn ->
      case fetch_group(namespace(config), channel_id) do
        {:ok, group} ->
          metadata = BindingMembership.project(group.metadata, context, :left)

          with {:ok, group} <- AuthZ.update_principal_group(group, %{metadata: metadata}) do
            if BindingMembership.all_left?(metadata) do
              clear_group_members(group, :all_participants_left)
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

  defp mark_all_participants_left(config, channel_id) do
    with_channel_lock(namespace(config), channel_id, fn ->
      case fetch_group(namespace(config), channel_id) do
        {:ok, group} ->
          metadata = BindingMembership.mark_all_left(group.metadata)

          with {:ok, group} <- AuthZ.update_principal_group(group, %{metadata: metadata}) do
            clear_group_members(group, :channel_gone)
          end

        {:error, :not_found} ->
          {:ok, %{status: :ignored_missing_group}}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp clear_group_members(%Group{} = group, reason) do
    with {:ok, result} <- AuthZ.replace_static_group_members(group.id, :im_group, []) do
      {:ok,
       %{
         status: reason,
         group_id: group.id,
         removed_memberships: result.removed_memberships
       }}
    end
  end

  defp mark_missing_channels_left(context, config, observed_channel_ids) do
    observed = MapSet.new(observed_channel_ids)
    provider = namespace(config)

    groups =
      ExternalBinding
      |> join(:inner, [binding], group in Group, on: group.id == binding.group_id)
      |> where(
        [binding, group],
        binding.provider == ^provider and binding.external_kind == :im_group and
          group.domain == :im_group
      )
      |> select([binding, group], {binding.external_id, group.metadata})
      |> Repo.all()

    groups
    |> Enum.reject(fn {channel_id, _metadata} -> MapSet.member?(observed, channel_id) end)
    |> Enum.filter(fn {_channel_id, metadata} ->
      BindingMembership.joined?(metadata, context)
    end)
    |> Enum.reduce_while({:ok, 0}, fn {channel_id, _metadata}, {:ok, count} ->
      case mark_participant_left(context, config, channel_id) do
        {:ok, _result} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp with_channel_lock(provider, channel_id, fun) when is_binary(channel_id) do
    Repo.transact(fn repo ->
      SQL.query!(repo, "SELECT pg_advisory_xact_lock(hashtext($1))", [
        "slack_channel:#{provider}:#{channel_id}"
      ])

      fun.()
    end)
  end

  defp with_channel_lock(_provider, _channel_id, _fun), do: {:error, :missing_channel_id}

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

  defp namespace(config), do: Map.get(config, "platformSubjectNamespace", "slack-main")

  defp runtime_bot_user_id(config),
    do: Map.get(config, "runtimeBotUserID") || Map.get(config, "botUserID")

  defp channel_id_from_signal("slack:" <> encoded), do: URI.decode(encoded)
  defp channel_id_from_signal(_value), do: nil
end
