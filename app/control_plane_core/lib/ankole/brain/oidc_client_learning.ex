defmodule Ankole.Brain.OIDCClientLearning do
  @moduledoc """
  Pulls stored OIDC Client conversations into Source-owned media pages.

  Each page keeps its learned revision and audience in Object.meta. A changed
  conversation replaces that page's facts atomically. Source defaults apply
  when a conversation first enters Brain; later edits do not widen its audience.
  """

  import Ecto.Query

  alias Ankole.AIGateway.OIDCClientConversations
  alias Ankole.Brain.Claims
  alias Ankole.Brain.Config
  alias Ankole.Brain.Jobs.LearnSource
  alias Ankole.Brain.Markdoc
  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Object
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
      |> where([object], object.managed_by_source_id == ^source.id)
      |> select([object], struct(object, [:id, :slug, :meta, :content_hash, :deleted_at]))
      |> Repo.all()
      |> Map.new(&{&1.meta["conversation_id"], &1})

    OIDCClientConversations.conversations(source.upstream_id)
    |> Enum.flat_map(fn conversation ->
      object = objects[conversation.id]

      if object && object.meta["source_revision"] == conversation.revision,
        do: [],
        else: [{conversation, object}]
    end)
  end

  defp learn_conversation(source, conversation, previous) do
    material = OIDCClientConversations.read(source.upstream_id, conversation.id)
    content = Enum.map_join(material.requests, "\n", &JSON.encode!/1)

    scope =
      if previous,
        do: previous.meta["audience_scope"],
        else: source.default_audience_scope || "principal:#{conversation.subject_uid}"

    slug = "media/oidc-#{source.id}-#{conversation.id}"
    title = "#{source.name} / #{conversation.id}"

    attrs = %{
      slug: slug,
      subtype: "conversation",
      title: title,
      body: Markdoc.wrap("~~~json\n#{content}\n~~~", scope),
      meta: %{
        "conversation_id" => conversation.id,
        "source_revision" => material.revision,
        "audience_scope" => scope
      }
    }

    with {:ok, extraction} <-
           SourceLearning.extract_items(slug, title, conversation_excerpts(material.requests)),
         {:ok, {object, written}} <-
           Repo.transact(fn repo ->
             with {:ok, current} <- Sources.lock_active(repo, source),
                  :ok <- ensure_current(repo, current, source, attrs.slug, previous),
                  {:ok, object} <- Objects.upsert_source_projection(current, attrs, repo: repo),
                  session = "source:#{source.id}",
                  _expired = Claims.expire_source_session_facts(repo, object.slug, session),
                  {:ok, written} <-
                    SourceLearning.write_claims(repo, object, extraction.items, scope, session),
                  {:ok, _source} <-
                    repo.update(
                      Source.changeset(current, %{last_sync_at: DateTime.utc_now(:microsecond)})
                    ) do
               {:ok, {object, written}}
             end
           end) do
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

  defp ensure_current(repo, current, source, slug, previous) do
    object = Object |> where([object], object.slug == ^slug) |> lock("FOR UPDATE") |> repo.one()

    case {object, previous} do
      {nil, nil} when current.default_audience_scope == source.default_audience_scope ->
        :ok

      {%Object{content_hash: hash, deleted_at: deleted},
       %Object{content_hash: hash, deleted_at: deleted}} ->
        :ok

      _changed ->
        {:error, :stale_run}
    end
  end
end
