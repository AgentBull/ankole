defmodule Ankole.Pod.Comments.Wakeups do
  @moduledoc """
  Detects `@agent` mentions in Page comments, acquires outermost work locks in
  `Ankole.LockOrder` sequence, enforces the triple authorization gate, and emits
  idempotent wakeup signals.
  """

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.{AuthZ, Conversations, Principals, Signals}
  alias Ankole.Pod.Access
  alias Ankole.Pod.Pages.Mentions
  alias Ankole.Principals.Principal
  alias Ankole.Sessions.{Key, Queue}

  @wakeup_signal_type "pod.page_comment.addressed"
  @principal_md_mention_regex ~r/@\[[^\]]*\]\(principal:([^)\s]+)\)/

  def wakeup_signal_type, do: @wakeup_signal_type

  def preflight_candidates(
        %AuthZ.Actor{turn_authority: nil, principal: %{type: :human, uid: author_uid}},
        attrs
      ) do
    body_text = Ankole.Attrs.get(attrs, :body) || ""
    explicit_uids = Ankole.Attrs.get(attrs, :mentioned_agent_uids) || []

    if not is_binary(body_text) or
         (explicit_uids == [] and not String.contains?(body_text, "@") and
            not String.contains?(body_text, "<mention")) do
      []
    else
      active_agents =
        Principals.list_principals!(
          query: [filter: [type: :agent, status: :active], load: [:agent]]
        )

      explicit =
        explicit_uids
        |> Enum.filter(&is_binary/1)
        |> MapSet.new()

      in_body = MapSet.new(extract_body_agent_uids(body_text, active_agents, author_uid))
      wanted = MapSet.union(explicit, in_body)

      Enum.filter(active_agents, &MapSet.member?(wanted, &1.uid))
    end
  end

  def preflight_candidates(_actor, _attrs), do: []

  def extract_body_agent_uids(body, agents, author_uid \\ nil)
  def extract_body_agent_uids(nil, _agents, _author_uid), do: []

  def extract_body_agent_uids(body_text, agents, author_uid)
      when is_binary(body_text) and is_list(agents) do
    xml_uids = Mentions.principal_uids(body_text)

    md_uids =
      @principal_md_mention_regex
      |> Regex.scan(body_text, capture: :all_but_first)
      |> List.flatten()

    direct_matches =
      Enum.flat_map(agents, fn agent ->
        uid_mentioned? = token_mentioned?(body_text, agent.uid)

        personal_name? =
          case agent.agent do
            %Ankole.Principals.Agent{type: :personal_assistant, owner_principal_uid: owner_uid} ->
              is_nil(author_uid) or owner_uid == author_uid

            _ ->
              true
          end

        name_mentioned? =
          personal_name? and is_binary(agent.display_name) and
            String.trim(agent.display_name) != "" and
            token_mentioned?(body_text, String.trim(agent.display_name))

        if uid_mentioned? or name_mentioned?, do: [agent.uid], else: []
      end)

    Enum.uniq(xml_uids ++ md_uids ++ direct_matches)
  end

  def prepare_locks_in_tx(actor, page_id, candidate_agents) do
    human_uid = AuthZ.Actor.uid(actor)
    agent_uids = Enum.map(candidate_agents, & &1.uid)

    targets =
      Enum.map(candidate_agents, fn agent ->
        conv_id =
          Conversations.find_anchor_page_conversation_id(page_id, agent.uid) ||
            Ankole.Ecto.UUIDv7.autogenerate()

        %{agent: agent, agent_uid: agent.uid, conversation_id: conv_id}
      end)

    {:ok, locked_principals} =
      Principals.lock_principals_in_tx(Enum.sort(Enum.uniq([human_uid | agent_uids])))

    principal_by_uid = locked_principals |> Ankole.Ash.load!(:agent) |> Map.new(&{&1.uid, &1})

    :ok =
      Queue.lock_sessions_in_tx(
        Enum.map(targets, &{&1.agent_uid, Key.conversation(&1.conversation_id)})
      )

    refreshed_targets =
      Enum.flat_map(targets, fn target ->
        case Map.get(principal_by_uid, target.agent_uid) do
          %Principal{type: :agent, status: :active} = locked_agent ->
            [%{target | agent: locked_agent}]

          _ ->
            []
        end
      end)

    %{
      targets: refreshed_targets,
      agents: Enum.map(refreshed_targets, & &1.agent)
    }
  end

  def maybe_wake_in_tx(_actor, _page, _comment, _root, %{targets: []}, _previous_uids, _now),
    do: {:ok, []}

  def maybe_wake_in_tx(actor, page, comment, root, %{targets: targets}, previous_uids, now) do
    previous_set = MapSet.new(previous_uids)
    effective_root = root || comment

    targets
    |> Enum.reject(&MapSet.member?(previous_set, &1.agent_uid))
    |> Enum.reduce_while({:ok, []}, fn target, {:ok, acc} ->
      if authorized_comment_wakeup?(actor, target.agent, page) do
        with {:ok, conversation, created?} <-
               ensure_anchor_conversation_in_tx(
                 actor,
                 target.agent,
                 target.conversation_id,
                 page,
                 now
               ),
             {:ok, signal} <-
               accept_comment_wakeup_signal_in_tx(
                 actor,
                 target.agent,
                 conversation,
                 page,
                 comment,
                 effective_root,
                 now
               ) do
          next_acc =
            if DateTime.compare(signal.occurred_at, now) == :eq do
              [
                %{
                  signal: signal,
                  conversation_id: conversation.id,
                  created_conversation?: created?,
                  agent_uid: target.agent.uid,
                  session_id: signal.session_id
                }
                | acc
              ]
            else
              acc
            end

          {:cont, {:ok, next_acc}}
        else
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, woken} -> {:ok, Enum.reverse(woken)}
      error -> error
    end
  end

  def publish_committed([]), do: :ok

  def publish_committed(woken) when is_list(woken) do
    Signals.publish_committed(Enum.map(woken, & &1.signal))

    Enum.each(woken, fn item ->
      if item.created_conversation? do
        Ankole.Conversations.Events.publish_committed([{item.conversation_id, :message}])
      end

      Ankole.Sessions.Events.publish_status(item.agent_uid, item.session_id)
    end)
  end

  defp token_mentioned?(body_text, token) do
    escaped = Regex.escape(token)

    case Regex.compile("(?<![\\p{L}\\p{N}_-])@" <> escaped <> "(?![\\p{L}\\p{N}_-])", "iu") do
      {:ok, regex} -> Regex.match?(regex, body_text)
      _ -> false
    end
  end

  defp authorized_comment_wakeup?(actor, %Principal{uid: agent_uid} = agent_principal, page) do
    human_can_chat? =
      AuthZ.authorize(actor, "agent:#{agent_uid}", "chat", AuthZ.Actor.request_context(actor)) ==
        :ok

    primary_ready? =
      match?(
        {:ok, %{"provider_id" => provider_id, "model" => model}}
        when is_binary(provider_id) and is_binary(model),
        ModelProfiles.get_model_profile(agent_uid, "primary")
      )

    agent_can_view_node? =
      match?({:ok, _}, Access.authorize(AuthZ.Actor.new(agent_principal), page, "node_view"))

    human_can_chat? and primary_ready? and agent_can_view_node?
  end

  defp ensure_anchor_conversation_in_tx(actor, agent, conv_id, page, now) do
    Conversations.ensure_anchor_page_conversation_in_tx(
      actor,
      agent,
      conv_id,
      page.id,
      page.title || page.name || "",
      now
    )
  end

  defp accept_comment_wakeup_signal_in_tx(actor, agent, conversation, page, comment, root, now) do
    human_uid = AuthZ.Actor.uid(actor)

    Signals.accept_in_tx(%{
      producer: :kernel,
      source: "control-plane://pod-comments",
      id: "pod-comment:#{comment.id}:#{agent.uid}",
      type: @wakeup_signal_type,
      subject: page.id,
      target: %{agent_uid: agent.uid, conversation_id: conversation.id},
      sender: human_uid,
      time: now,
      data: %{
        "conversation_id" => conversation.id,
        "node_id" => page.id,
        "page_id" => page.id,
        "node_type" => to_string(page.type),
        "node_title" => page.title || page.name || "",
        "comment_id" => comment.id,
        "root_id" => root.id,
        "author_uid" => human_uid,
        "author_name" => principal_display_name(actor.principal),
        "quote" => root.quote,
        "anchor" => root.anchor,
        "body_markdown" => comment.body
      }
    })
  end

  defp principal_display_name(principal) do
    name = principal.display_name
    if is_binary(name) and String.trim(name) != "", do: name, else: principal.uid
  end
end
