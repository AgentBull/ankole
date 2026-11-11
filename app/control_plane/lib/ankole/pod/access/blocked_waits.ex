defmodule Ankole.Pod.Access.BlockedWaits do
  @moduledoc """
  Records blocked Page `node_view` attempts during conversation turns and grants
  view access inline to resume the Agent without replaying prior tool calls.
  """

  import Bitwise

  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations.Delivery.{Interactions, PreviewStates, ReplyPresentation}
  alias Ankole.Pod.{Access, Bases, Page, Pages}
  alias Ankole.Pod.Access.{Explain, Graph}
  alias Ankole.Pod.Pages.Sharing
  alias Ankole.Pod.Pages.Tree, as: Nodes
  alias Ankole.Repo
  alias Ankole.Signals.Signal

  @page_id_ops ~w(
    pages.read
    pages.sharing
    pages.children
    pages.write
    pages.append
    pages.update
    pages.move
    pages.delete
    comments.list
    comments.show
    comments.reply
    comments.resolve
    files.manifest
    files.download
    files.upload
    office.inspect
    office.render
    office.commands
    office.apply
    office.to_document
    applets.publish
    applets.call
    base.tables
    base.create_table
    jobs.actions
    jobs.runs
    jobs.list
    jobs.get_run
    jobs.schedules.list
    jobs.schedules.runs
    jobs.webhooks.list
  )

  @table_id_ops ~w(
    base.schema
    base.query
    base.aggregate
    base.configure_table
    base.delete_table
    base.create_field
    base.update_field
    base.delete_field
    base.create_view
    base.update_view
    base.delete_view
    base.write
    base.copy
  )

  def maybe_record_blocked_turn(ctx, operation, params, reason)
      when reason in [:not_found, :forbidden] and is_map(ctx) and is_map(params) do
    with %{
           actor:
             %Actor{
               principal: %{uid: agent_uid} = agent_principal,
               turn_authority: {%Ankole.Sessions.RunRef{} = ref, _}
             } = turn_actor
         } <- ctx,
         {:conversation, conversation_id} <- Ankole.Sessions.Key.parse(ref.session_id),
         {:ok, %{} = _conversation} <- Ankole.Conversations.get_conversation(conversation_id),
         {:ok, page_id} <- target_page_id(operation, params),
         {:ok, %Page{deleted_at: nil} = page} <- Pages.fetch(page_id),
         {:ok, path} <- Access.path(page),
         true <- Enum.all?(path, &is_nil(&1.deleted_at)),
         {:ok, grant_target_uid} <-
           resolve_grant_target_uid(turn_actor, agent_principal, page, path) do
      payload = %{
        "page_id" => page.id,
        "conversation_id" => conversation_id,
        "agent_uid" => agent_uid,
        "grant_target_uid" => grant_target_uid,
        "operation" => operation,
        "required_action" => "node_view"
      }

      _ =
        if Repo.in_transaction?() do
          write_checkpoint_in_tx(ref.signal_id, payload)
        else
          Repo.transact_top_level(fn -> write_checkpoint_in_tx(ref.signal_id, payload) end)
        end

      :ok
    else
      _ -> :ok
    end
  end

  def maybe_record_blocked_turn(_ctx, _operation, _params, _reason), do: :ok

  defp write_checkpoint_in_tx(signal_id, payload) do
    case Ankole.Signals.lock_signal_in_tx(signal_id) do
      %Signal{} = event ->
        loaded = PreviewStates.load(event)

        checkpoint =
          (PreviewStates.get(loaded).checkpoint || %{})
          |> Map.put("blocked_page_access", payload)

        PreviewStates.put_checkpoint_in_tx(loaded, checkpoint)

      nil ->
        {:ok, nil}
    end
  end

  defp target_page_id(operation, params) when operation in @page_id_ops do
    raw = params["id"] || params["page_id"] || params["parent_id"]
    if is_binary(raw), do: Ecto.UUID.cast(raw), else: :error
  end

  defp target_page_id(operation, params) when operation in @table_id_ops do
    with raw when is_binary(raw) <- params["id"],
         {:ok, table_id} <- Ecto.UUID.cast(raw),
         {:ok, table} <- Bases.fetch_table(table_id) do
      {:ok, table.page_id}
    else
      _ -> :error
    end
  end

  defp target_page_id(_operation, _params), do: :error

  defp resolve_grant_target_uid(turn_actor, agent_principal, page, path) do
    root = hd(path)
    base_actor = Actor.new(agent_principal, authn: turn_actor.authn)

    candidate_uid =
      case Access.authorize(base_actor, page, "node_view") do
        {:error, _} ->
          Ankole.Principals.authority_uid(agent_principal.uid)

        {:ok, _} ->
          case Access.authorize(turn_actor, page, "node_view") do
            {:error, _} ->
              explained = Explain.explain(turn_actor, page, "node_view")

              stage_4 =
                Enum.find(explained.stages, &(&1.id == "brain_disclosure_gate")) ||
                  %{details: %{}}

              case stage_4.details["missing_reader_uids"] do
                [single_uid] when is_binary(single_uid) -> single_uid
                _ -> nil
              end

            {:ok, _} ->
              nil
          end
      end

    with uid when is_binary(uid) <- candidate_uid,
         {:ok, %{status: :active} = target_principal} <- Ankole.Principals.get_principal(uid),
         false <- target_principal.membership == :guest and not is_nil(root.private_owner_uid) do
      {:ok, uid}
    else
      _ -> :error
    end
  end

  def blocked_page_ids_for_signal(signal_id) when is_binary(signal_id) do
    case PreviewStates.get(signal_id).checkpoint do
      %{"blocked_page_access" => %{"page_id" => page_id}} when is_binary(page_id) ->
        MapSet.new([page_id])

      _ ->
        MapSet.new()
    end
  end

  def blocked_page_ids_for_signal(_), do: MapSet.new()

  def ungranted_wait_for_signal(signal_id) when is_binary(signal_id) do
    case PreviewStates.get(signal_id).checkpoint do
      %{"blocked_page_access" => %{"page_id" => page_id, "grant_target_uid" => target_uid} = wait}
      when is_binary(page_id) and is_binary(target_uid) ->
        if still_blocked?(page_id, target_uid), do: wait, else: nil

      _ ->
        nil
    end
  end

  def ungranted_wait_for_signal(_), do: nil

  defp still_blocked?(page_id, target_uid) do
    with {:ok, %Page{deleted_at: nil} = page} <- Pages.fetch(page_id),
         {:ok, path} <- Access.path(page),
         true <- Enum.all?(path, &is_nil(&1.deleted_at)),
         {:ok, principal} <- Ankole.Principals.get_principal(target_uid) do
      not match?({:ok, _}, Access.authorize(Actor.new(principal), page, "node_view"))
    else
      _ -> false
    end
  end

  def interaction_local_id(%{"page_id" => page_id}), do: "access_blocked:" <> page_id

  def client_payload(%{} = wait, signal_id) do
    local_id = interaction_local_id(wait)

    %{
      "interaction_id" => signal_id <> ":" <> local_id,
      "page_id" => wait["page_id"],
      "agent_uid" => wait["agent_uid"],
      "grant_target_uid" => wait["grant_target_uid"],
      "operation" => wait["operation"],
      "required_action" => wait["required_action"] || "node_view"
    }
  end

  def build_presentation(%{} = wait, signal_id, answer_text) do
    local_id = interaction_local_id(wait)
    conversation_id = wait["conversation_id"]

    prompt =
      case answer_text do
        text when is_binary(text) and text != "" ->
          text

        _ ->
          "Grant page view access to continue this request."
      end

    url =
      if is_binary(conversation_id) do
        String.trim_trailing(AnkoleWeb.Endpoint.url(), "/") <> "/chat/" <> conversation_id
      else
        String.trim_trailing(AnkoleWeb.Endpoint.url(), "/")
      end

    ReplyPresentation.new(state: "awaiting_input")
    |> ReplyPresentation.link_interaction_request(signal_id, %{
      "interaction_id" => local_id,
      "prompt" => prompt,
      "label" => "Review access in Pod",
      "url" => url
    })
  end

  @doc """
  Enriches `access_blocked` message cards for `viewer_actor` inside the caller's
  read transaction without exposing page titles or ACL details to unauthorized viewers.
  """
  def native_states([], _viewer_actor), do: %{}
  def native_states(_messages, nil), do: %{}

  def native_states(messages, %Actor{} = viewer_actor) when is_list(messages) do
    viewer_reachable =
      case Graph.reachable_anchors(viewer_actor) do
        {:ok, rows} -> rows
        _ -> %{}
      end

    Map.new(messages, fn message ->
      blocked = get_in(message.rich_content || %{}, ["access_blocked"]) || %{}
      page_id = blocked["page_id"]
      agent_uid = blocked["agent_uid"] || message.author_uid
      target_uid = blocked["grant_target_uid"] || agent_uid

      state =
        enrich_message_blocked_state(
          viewer_actor,
          viewer_reachable,
          page_id,
          agent_uid,
          target_uid
        )

      {message.id, state}
    end)
  end

  defp enrich_message_blocked_state(
         viewer_actor,
         viewer_reachable,
         page_id,
         agent_uid,
         target_uid
       ) do
    agent_name = principal_display_name(agent_uid)
    target_principal = fetch_principal(target_uid)

    target_name =
      if target_principal, do: Ankole.Principals.display_name(target_principal), else: target_uid

    with true <- is_binary(page_id),
         {:ok, %Page{deleted_at: nil} = page} <- Pages.fetch(page_id),
         {:ok, path} <- Access.path(page),
         true <- Enum.all?(path, &is_nil(&1.deleted_at)) do
      bits = Graph.page_bits(page, viewer_reachable)
      can_view? = band(bits, 1) != 0
      can_manage? = band(bits, 8) != 0

      already_granted? =
        case target_principal do
          %{} = p -> match?({:ok, _}, Access.authorize(Actor.new(p), page, "node_view"))
          _ -> false
        end

      guest_private? =
        target_principal != nil and target_principal.membership == :guest and
          not is_nil(hd(path).private_owner_uid)

      explain =
        if can_manage? and not is_nil(target_principal) do
          Actor.new(target_principal)
          |> Explain.explain(page, "node_view",
            viewer_actor: viewer_actor,
            viewer_reachable: viewer_reachable
          )
          |> Ankole.JSON.plain()
        else
          nil
        end

      %{
        "page_title" => if(can_view?, do: page.title),
        "page_type" => if(can_view?, do: Atom.to_string(page.type)),
        "agent_name" => agent_name,
        "target_name" => target_name,
        "can_grant" => can_manage? and not already_granted? and not guest_private?,
        "already_granted" => already_granted?,
        "explain" => explain
      }
    else
      _ ->
        %{
          "page_title" => nil,
          "page_type" => nil,
          "agent_name" => agent_name,
          "target_name" => target_name,
          "can_grant" => false,
          "already_granted" => false,
          "explain" => nil
        }
    end
  end

  defp fetch_principal(uid) when is_binary(uid) do
    case Ankole.Principals.get_principal(uid) do
      {:ok, principal} -> principal
      _ -> nil
    end
  end

  defp fetch_principal(_), do: nil

  defp principal_display_name(uid) when is_binary(uid) do
    case fetch_principal(uid) do
      %{} = principal -> Ankole.Principals.display_name(principal)
      nil -> uid
    end
  end

  defp principal_display_name(_), do: ""

  @doc """
  Grants `view` access on the blocked Page to `grant_target_uid` and wakes the
  waiting Agent turn in strictly ascending lock order:
  Rank 2 (`page-tree`) -> Rank 2.5 (`page-root`) -> Rank 3 (`principals`) ->
  Rank 9 (`session`) -> Rank 10/11 (`resolve_external_wait_in_tx`) ->
  Rank 12 (`Sharing.update_sharing_in_tx`).
  """
  def grant_and_continue(%Actor{} = actor, conversation_id, interaction_id)
      when is_binary(conversation_id) and is_binary(interaction_id) do
    human_actor = %{actor | turn_authority: nil}

    with {:ok, outcome} <-
           Repo.transact_top_level(
             fn -> grant_and_continue_in_tx(human_actor, conversation_id, interaction_id) end,
             after_commit: &__MODULE__.publish_after_commit/1
           ) do
      Ankole.Conversations.get(human_actor, outcome.conversation_id)
    end
  end

  @doc false
  def grant_and_continue_in_tx(%Actor{} = actor, conversation_id, interaction_id) do
    alias Ankole.Conversations.{Native, Queries}

    actor_uid = Actor.uid(actor)
    actor_name = Ankole.Principals.display_name(actor.principal)
    now = DateTime.utc_now(:microsecond)

    with {:ok, conversation_id} <- Queries.cast_id(conversation_id),
         [signal_id, "access_blocked:" <> page_id = local_id] <-
           String.split(interaction_id, ":", parts: 2),
         {:ok, signal_id} <- Ecto.UUID.cast(signal_id),
         {:ok, page_id} <- Ecto.UUID.cast(page_id),
         :ok <- Ankole.Pod.lock_tree_in_tx(),
         :ok <- Nodes.lock_roots(Nodes.root_ids([page_id])),
         {:ok, %Signal{} = source} <- Ankole.Signals.get_signal(signal_id),
         true <- source_belongs_to_conversation?(source, conversation_id),
         true <- Native.visible_conversation?(actor, conversation_id),
         %{"page_id" => ^page_id, "grant_target_uid" => grant_target_uid} <-
           (PreviewStates.get(source).checkpoint || %{})["blocked_page_access"],
         :ok <-
           Native.lock_session_participants_in_tx(source, [actor_uid, grant_target_uid]),
         :ok <-
           Ankole.Sessions.Queue.lock_sessions_in_tx(
             Ankole.Conversations.peer_session_keys(source)
           ),
         answer = %{
           "kind" => "access_granted",
           "value" => "Granted view access to @#{grant_target_uid}"
         },
         {:ok, woken} <-
           Interactions.resolve_external_wait_in_tx(
             source,
             local_id,
             actor_uid,
             actor_name,
             answer,
             now
           ),
         {:ok, updated_page} <-
           ensure_view_grant_in_tx(actor, page_id, grant_target_uid) do
      {:ok,
       %{
         conversation_id: conversation_id,
         page: updated_page,
         woken: woken
       }}
    else
      false -> {:error, :conversation_not_found}
      {:error, _} = error -> error
      _ -> {:error, :interaction_not_pending}
    end
  end

  defp ensure_view_grant_in_tx(actor, page_id, grant_target_uid) do
    with {:ok, %Page{deleted_at: nil} = page} <- Pages.fetch(page_id),
         {:ok, path} <- Access.path(page),
         true <- Enum.all?(path, &is_nil(&1.deleted_at)),
         {:ok, target_principal} <- Ankole.Principals.get_principal(grant_target_uid) do
      if match?({:ok, _}, Access.authorize(Actor.new(target_principal), page, "node_view")) do
        with {:ok, _} <- Access.authorize(actor, page, "node_manage") do
          {:ok, nil}
        end
      else
        Sharing.update_sharing_in_tx(actor, page_id, %{
          upserts: [
            %{principal_uid: grant_target_uid, role: :view, target_scope: "container"}
          ]
        })
      end
    else
      false -> {:error, :not_found}
      {:ok, %Page{}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp source_belongs_to_conversation?(%Signal{conversation_id: cid}, cid), do: true

  defp source_belongs_to_conversation?(%Signal{conversation_id: peer_cid}, conversation_id)
       when is_binary(peer_cid) do
    case Ankole.Conversations.peer_exchange(peer_cid) do
      %{origin_conversation_id: ^conversation_id} -> true
      _ -> false
    end
  end

  defp source_belongs_to_conversation?(_, _), do: false

  @doc false
  def publish_after_commit(%{conversation_id: conversation_id, page: page, woken: woken}) do
    if page, do: Pages.committed(page)

    case woken do
      %Signal{} = signal -> Ankole.Signals.publish_committed([signal])
      other -> Ankole.Conversations.Native.publish_native_change(other)
    end

    Ankole.Conversations.Events.publish_message(conversation_id)
    :ok
  end
end
