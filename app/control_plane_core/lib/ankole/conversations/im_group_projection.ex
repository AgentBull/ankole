defmodule Ankole.Conversations.IMGroupProjection do
  @moduledoc false

  alias Ankole.Logging
  alias Ankole.AuthZ

  alias Ankole.Conversations.AdapterContext
  alias Ankole.Signals.BindingMembership
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.External
  alias Ankole.Conversations.IMGroupMembers

  def ensure_group(namespace, external_id, attrs, %AdapterContext{} = context, opts) do
    %{namespace: namespace, external_id: external_id}
    |> Ankole.Conversations.ensure_im_group(attrs, context, opts)
    |> Ankole.Errors.reason()
  end

  @doc false
  def ensure_group_in_tx(
        repo,
        %{namespace: namespace, external_id: external_id},
        attrs,
        context,
        opts
      ) do
    lock_group(repo, namespace, external_id)

    result =
      case group(namespace, external_id, true) do
        {:ok, existing} ->
          changes = %{metadata: BindingMembership.project(existing.metadata, context, :joined)}

          changes =
            if is_binary(attrs["name"]),
              do: Map.put(changes, :display_name, attrs["name"]),
              else: changes

          AuthZ.profile_group(existing, changes)

        {:error, :not_found} ->
          AuthZ.create_group(%{
            name: "#{namespace}:im_group:#{String.downcase(external_id)}",
            display_name: attrs["name"] || Keyword.fetch!(opts, :default_display_name),
            domain: :im_group,
            kind: :static,
            metadata: BindingMembership.project(%{}, context, :joined)
          })
      end

    with {:ok, group} <- result,
         {:ok, _binding} <-
           upsert_binding(
             namespace,
             external_id,
             group.id,
             Keyword.fetch!(opts, :binding_metadata)
           ),
         {:ok, _channel} <-
           observe_room(repo, namespace, group.id, Keyword.fetch!(opts, :channel), context) do
      {:ok, group}
    end
  end

  def get_group(namespace, external_id), do: group(namespace, external_id, false)

  def mark_left(namespace, external_id, %AdapterContext{} = context) do
    update_membership(namespace, external_id, &BindingMembership.project(&1, context, :left))
  end

  def mark_all_left(namespace, external_id) do
    update_membership(namespace, external_id, &BindingMembership.mark_all_left/1)
  end

  def mark_missing_left(namespace, observed_ids, %AdapterContext{} = context) do
    observed = MapSet.new(observed_ids)

    bindings =
      AuthZ.list_external_bindings!(
        query: [
          filter: [provider: namespace, external_kind: :im_group],
          select: [:external_id, :group_id]
        ]
      )

    groups =
      AuthZ.list_groups!(
        query: [
          filter: [id: [in: Enum.map(bindings, & &1.group_id)], domain: :im_group],
          select: [:id, :metadata]
        ]
      )
      |> Map.new(&{&1.id, &1.metadata})

    bindings
    |> Enum.filter(&Map.has_key?(groups, &1.group_id))
    |> Enum.map(&{&1.external_id, Map.fetch!(groups, &1.group_id)})
    |> Enum.reject(fn {external_id, _metadata} -> MapSet.member?(observed, external_id) end)
    |> Enum.filter(fn {_external_id, metadata} ->
      BindingMembership.joined?(metadata, context)
    end)
    |> Enum.reduce_while({:ok, 0}, fn {external_id, _metadata}, {:ok, count} ->
      case mark_left(namespace, external_id, context) do
        {:ok, _result} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_membership(namespace, external_id, update) do
    %{namespace: namespace, external_id: external_id}
    |> Ankole.Conversations.update_im_group_membership(update)
    |> Ankole.Errors.reason()
  end

  @doc false
  def update_membership_in_tx(repo, %{namespace: namespace, external_id: external_id}, update) do
    lock_group(repo, namespace, external_id)

    with {:ok, group} <- group(namespace, external_id, true),
         {:ok, group} <- AuthZ.profile_group(group, %{metadata: update.(group.metadata)}),
         {:ok, result} <- clear_left_members(repo, group) do
      {:ok, Map.put(result, :group_id, group.id)}
    else
      {:error, :not_found} -> {:ok, %{status: :ignored_missing_group}}
      {:error, _reason} = error -> error
    end
  end

  defp clear_left_members(repo, group) do
    if BindingMembership.all_left?(group.metadata) do
      with {:ok, result} <- IMGroupMembers.replace_members_in_tx(repo, group.id, []) do
        {:ok, Map.put(result, :status, :all_left_members_cleared)}
      end
    else
      with {:ok, delta} <- IMGroupMembers.reconcile_agent_members_in_tx(repo, group.id) do
        {:ok, %{status: :participant_marked_left, removed_memberships: delta.removed_memberships}}
      end
    end
  end

  defp upsert_binding(namespace, external_id, group_id, metadata) do
    AuthZ.bind_external_binding(%{
      provider: namespace,
      external_kind: :im_group,
      external_id: external_id,
      group_id: group_id,
      metadata: metadata
    })
  end

  defp observe_room(repo, namespace, group_id, %{fact: fact, on_conflict: policy}, context) do
    fact = Map.put(fact, :principal_group_id, group_id)

    fact =
      case {policy, External.get_conversation(repo, fact.provider_conversation_id)} do
        {:keep_existing, %Conversation{principal_group_id: existing_id}}
        when is_binary(existing_id) and existing_id != group_id ->
          existing_namespace =
            AuthZ.list_external_bindings!(
              query: [
                filter: [group_id: existing_id, external_kind: :im_group],
                select: [:provider]
              ]
            )
            |> Enum.map(& &1.provider)
            |> List.first()

          Logging.warning(
            "conversations.im_group.channel_namespace_conflict",
            "IM group channel already belongs to another namespace",
            %{
              conversation_id: fact.provider_conversation_id,
              namespace: namespace,
              existing_namespace: existing_namespace,
              existing_group_id: existing_id,
              group_id: group_id
            }
          )

          Map.put(fact, :principal_group_id, nil)

        {:keep_existing, _channel} ->
          fact

        {:replace, _channel} ->
          fact
      end

    External.observe_conversation_in_tx(
      repo,
      %{agent_uid: context.agent_uid, name: context.binding_name},
      %{
        provider_conversation_id: fact.provider_conversation_id,
        title: fact.channel_name,
        external_kind: fact.channel_kind,
        reply_mode: fact.reply_mode,
        visibility: Map.get(fact, :channel_visibility),
        principal_group_id: fact.principal_group_id,
        metadata: Map.get(fact, :channel_metadata) || %{},
        raw_payload: Map.get(fact, :channel_raw_payload) || %{}
      },
      DateTime.utc_now(:microsecond)
    )
  end

  defp group(namespace, external_id, lock?) do
    group_ids =
      AuthZ.list_external_bindings!(
        query: [
          filter: [provider: namespace, external_kind: :im_group, external_id: external_id],
          select: [:group_id]
        ]
      )
      |> Enum.map(& &1.group_id)

    query = [filter: [id: [in: group_ids]]]
    query = if lock?, do: Keyword.put(query, :lock, :for_update), else: query

    case AuthZ.list_groups!(query: query) do
      [group] -> {:ok, group}
      [] -> {:error, :not_found}
    end
  end

  defp lock_group(repo, namespace, external_id) do
    Ankole.AdvisoryLock.lock!(repo, "im_group:#{namespace}:#{external_id}")

    :ok
  end
end
