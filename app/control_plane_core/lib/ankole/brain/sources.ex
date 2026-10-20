defmodule Ankole.Brain.Sources do
  @moduledoc """
  Durable lifecycle for registered Brain Sources.

  Source identity, archive state, row locking, and revision writeback live
  here. Each learning path still owns its extraction and projection rules.
  """

  import Ecto.Query, warn: false

  alias Ankole.Brain.Objects
  alias Ankole.Brain.Schemas.Source
  alias Ankole.Brain.Scope
  alias Ankole.Repo

  @doc "Lists Sources for the Console read model."
  @spec list_for_console(keyword()) :: [Source.t()]
  def list_for_console(opts) when is_list(opts) do
    limit = Keyword.fetch!(opts, :limit)

    Source
    |> order_by([source], desc: source.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec create(map()) :: {:ok, Source.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    %Source{}
    |> Source.changeset(attrs)
    |> Repo.insert()
  end

  @spec get_or_create(map()) :: {:ok, Source.t()} | {:error, term()}
  def get_or_create(attrs) when is_map(attrs) do
    changeset = Source.changeset(%Source{}, attrs)

    with {:ok, normalized} <- Ecto.Changeset.apply_action(changeset, :validate) do
      case Repo.get_by(Source, kind: normalized.kind, upstream_id: normalized.upstream_id) do
        %Source{} = source ->
          {:ok, source}

        nil ->
          case Repo.insert(changeset) do
            {:ok, source} ->
              {:ok, source}

            {:error, reason} ->
              case Repo.get_by(Source,
                     kind: normalized.kind,
                     upstream_id: normalized.upstream_id
                   ) do
                %Source{} = source -> {:ok, source}
                nil -> {:error, reason}
              end
          end
      end
    end
  end

  @spec archive(Ecto.UUID.t()) :: {:ok, Source.t()} | {:error, term()}
  def archive(source_id) do
    Repo.transact(fn repo ->
      with {:ok, source} <- mark_archived(repo, source_id) do
        if source.kind == "library",
          do: Objects.withdraw_library_projection(source, [], repo: repo)

        {:ok, source}
      end
    end)
  end

  @doc "Sets the audience for OIDC Client conversations that have not entered Brain yet."
  def update_default_scope(source_id, scope) do
    with :ok <- if(is_nil(scope), do: :ok, else: Scope.validate(scope)) do
      Repo.transact(fn repo ->
        with {:ok, source} <- lock_active(repo, %Source{id: source_id}),
             true <- source.kind == "oidc_client" do
          source |> Source.changeset(%{default_audience_scope: scope}) |> repo.update()
        else
          false -> {:error, {:invalid, "source_kind"}}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  defp mark_archived(repo, source_id) do
    source =
      Source |> where([source], source.id == ^source_id) |> lock("FOR UPDATE") |> repo.one()

    case source do
      %Source{archived_at: nil} = source ->
        source
        |> Source.changeset(%{archived_at: DateTime.utc_now(:microsecond)})
        |> repo.update()

      %Source{} = source ->
        {:ok, source}

      nil ->
        {:error, :not_found}
    end
  end

  @spec ensure_active(Source.t()) :: :ok | {:error, :source_archived}
  def ensure_active(%Source{archived_at: nil}), do: :ok
  def ensure_active(%Source{}), do: {:error, :source_archived}

  @spec lock_active(module(), Source.t()) :: {:ok, Source.t()} | {:error, term()}
  def lock_active(repo, %Source{id: source_id}) do
    Source
    |> where([source], source.id == ^source_id)
    |> lock("FOR UPDATE")
    |> repo.one()
    |> case do
      %Source{} = source ->
        case ensure_active(source) do
          :ok -> {:ok, source}
          {:error, _reason} = error -> error
        end

      nil ->
        {:error, :not_found}
    end
  end

  @spec record_revision(module(), Source.t(), String.t()) ::
          {:ok, Source.t()} | {:error, Ecto.Changeset.t()}
  def record_revision(repo, %Source{} = source, revision) when is_binary(revision) do
    source
    |> Source.changeset(%{
      upstream_revision: revision,
      last_sync_at: DateTime.utc_now(:microsecond)
    })
    |> repo.update()
  end

  @spec extraction_watermark(Source.t()) :: non_neg_integer() | nil
  def extraction_watermark(%Source{extracted_through_seq: seq}), do: seq

  def conversation_extraction_watermark(conversation_id) do
    case Repo.get_by(Source, kind: "conversation", upstream_id: conversation_id) do
      %Source{} = source -> extraction_watermark(source)
      nil -> nil
    end
  end

  @doc "Rewinds learning when a previously covered public Message changes."
  def invalidate_conversation_message_in_tx(repo, message, now) do
    case repo.one(
           from s in Source,
             where: s.kind == "conversation" and s.upstream_id == ^message.conversation_id,
             lock: "FOR UPDATE"
         ) do
      %Source{extracted_through_seq: seq} = source when is_integer(seq) and seq >= message.seq ->
        :ok = Ankole.Brain.Claims.withdraw_source_claims_in_tx(repo, source.id, now)

        {:ok, _} =
          source
          |> Ecto.Changeset.change(
            extracted_through_seq: 0,
            extracted_through_at: nil,
            upstream_revision: Ecto.UUID.generate()
          )
          |> repo.update()

        if is_nil(source.archived_at) and Ankole.Brain.Config.enabled?() do
          {:ok, _} = Ankole.Brain.Jobs.ProcessConversationSlice.enqueue(message.conversation_id)
        end

        :ok

      _ ->
        :ok
    end
  end

  @doc "Records a sequence boundary while the caller holds the Source row lock."
  def record_extraction_watermark(repo, %Source{id: id}, {%DateTime{} = at, seq})
      when is_integer(seq) and seq >= 0 do
    {1, _} =
      Source
      |> where([source], source.id == ^id)
      |> repo.update_all(set: [extracted_through_at: at, extracted_through_seq: seq])

    :ok
  end
end
