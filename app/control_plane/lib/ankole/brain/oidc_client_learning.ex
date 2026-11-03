defmodule Ankole.Brain.OIDCClientLearning do
  @moduledoc """
  Pulls stored OIDC Client conversations into Source-owned media pages.

  Each page keeps its learned revision and source node in Pod upstream state. A changed
  conversation replaces that page's facts atomically. Source defaults apply
  when a conversation first enters Brain; later edits do not widen its audience.
  """

  require Ash.Query

  alias Ankole.AIGateway.OIDCClientConversations
  alias Ankole.Brain.Config
  alias Ankole.Brain.Jobs.LearnSource
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Page, as: Object
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.SourceLearning
  alias Ankole.Brain.Sources
  alias Ankole.JSON
  alias Ankole.Logging
  alias Ankole.OIDC
  alias Ankole.Repo

  def sweep do
    if Config.enabled?() do
      Enum.count(OIDCClientConversations.client_ids(), fn client_id ->
        with {:ok, source} <- register(client_id),
             :ok <- Sources.ensure_active(source),
             [_ | _] <- pending_conversations(source),
             {:ok, _job} <- LearnSource.enqueue(source.id) do
          true
        else
          {:error, :source_archived} ->
            false

          [] ->
            false

          {:error, reason} ->
            Logging.warning("brain.oidc_client_sweep_failed", "OIDC Client Source scan failed", %{
              client_id: client_id,
              reason: inspect(reason)
            })

            false
        end
      end)
    else
      0
    end
  end

  def learn(%Source{kind: "oidc_client"} = source) do
    source
    |> pending_conversations()
    |> Enum.reduce_while(%{learned: 0, failed: []}, fn {conversation, object}, report ->
      case learn_conversation(source, conversation, object) do
        {:ok, _object} ->
          {:cont, %{report | learned: report.learned + 1}}

        {:error, :source_archived} ->
          {:halt, %{report | failed: [:source_archived]}}

        {:error, reason} ->
          {:cont, %{report | failed: [{conversation.id, reason} | report.failed]}}
      end
    end)
    |> case do
      %{failed: [], learned: count} -> {:ok, %{status: :learned, conversations: count}}
      %{failed: [:source_archived]} -> {:error, :source_archived}
      %{failed: failures} -> {:error, {:conversation_learning_failed, failures}}
    end
  end

  defp register(client_id) do
    name =
      case OIDC.get_client(client_id) do
        {:ok, client} -> client.name
        {:error, :not_found} -> "OIDC Client #{client_id}"
      end

    Sources.get_or_create(%{kind: "oidc_client", upstream_id: client_id, name: name})
  end

  defp pending_conversations(source) do
    objects =
      Object
      |> Ash.Query.filter(managed_by_source_id == ^source.id)
      |> Ash.Query.select([:id, :slug, :meta, :content_hash, :deleted_at])
      |> Ankole.Ash.read!()
      |> Map.new(fn page ->
        state = upstream_state(page)
        {state["conversation_id"], {page, state}}
      end)

    OIDCClientConversations.conversations(source.upstream_id)
    |> Enum.flat_map(fn conversation ->
      case objects[conversation.id] do
        {_page, %{"source_revision" => revision}} when revision == conversation.revision -> []
        {page, _state} -> [{conversation, page}]
        nil -> [{conversation, nil}]
      end
    end)
  end

  defp learn_conversation(source, conversation, previous) do
    material = OIDCClientConversations.read(source.upstream_id, conversation.id)
    content = Enum.map_join(material.requests, "\n", &JSON.encode!/1)

    scope =
      if previous,
        do: upstream_state(previous)["source_node_id"],
        else:
          source.default_source_node_id || Ankole.Brain.Scope.principal(conversation.subject_uid)

    slug = "media/oidc-#{source.id}-#{conversation.id}"
    title = "#{source.name} / #{conversation.id}"

    attrs = %{
      slug: slug,
      subtype: "conversation",
      title: title,
      body: "~~~json\n#{content}\n~~~",
      source_node_id: scope,
      upstream_state: %{
        "conversation_id" => conversation.id,
        "source_revision" => material.revision,
        "source_node_id" => scope
      }
    }

    with {:ok, extraction} <-
           SourceLearning.extract_items(slug, title, conversation_excerpts(material.requests)),
         {:ok, %{object: object, written: written}} <-
           Repo.transact_top_level(
             fn ->
               learn_conversation_in_tx(%{
                 source: source,
                 attrs: attrs,
                 previous: previous,
                 items: extraction.items,
                 scope: scope
               })
             end,
             after_commit: &Ankole.Brain.Namespace.committed/1
           ) do
      if written.rejected > 0 do
        Logging.warning(
          "brain.oidc_client_items_rejected",
          "Conversation items failed write validation",
          %{
            source_id: source.id,
            conversation_id: conversation.id,
            rejected: written.rejected,
            reasons: written.reject_reasons
          }
        )
      end

      {:ok, object}
    end
  end

  @doc false
  # Replaces the page and the Claims of one conversation in the transaction of
  # the `:learn_oidc_conversation` action. The locked Source and page fence an
  # archive and a concurrent run.
  def learn_conversation_in_tx(%{source: source, attrs: attrs} = run) do
    Ankole.Pod.Pages.Tree.lock_tree()
    session = "source:#{source.id}"

    with {:ok, current} <- Sources.lock_active(source),
         :ok <- ensure_current(current, source, attrs.slug, run.previous),
         {:ok, object} <- Objects.upsert_source_projection_in_tx(current, attrs),
         {:ok, written} <- SourceLearning.write_claims(object, run.items, object.id, session),
         {:ok, _source} <- Ankole.Ash.update(current, :record_sync, %{}) do
      {:ok, %{object: object, written: written}}
    end
  end

  defp upstream_state(page) do
    {:ok, properties} = Ankole.Pod.Pages.fetch(page.id)
    properties.upstream_state
  end

  defp conversation_excerpts(requests) do
    for request <- requests,
        origin <- [:input, :output],
        message <- Map.fetch!(request, origin),
        text <- SourceLearning.text_excerpts(message["text"]) do
      request
      |> Map.merge(%{input: [], output: []})
      |> Map.put(origin, [Map.put(message, "text", text)])
      |> JSON.encode!()
    end
  end

  defp ensure_current(current, source, slug, previous) do
    object =
      case Objects.lock_object_in_tx(slug) do
        {:ok, page} -> page
        {:error, :not_found} -> nil
      end

    case {object, previous} do
      {nil, nil} when current.default_source_node_id == source.default_source_node_id ->
        :ok

      {%Object{content_hash: hash, deleted_at: deleted},
       %Object{content_hash: hash, deleted_at: deleted}} ->
        :ok

      _changed ->
        {:error, :stale_run}
    end
  end
end
