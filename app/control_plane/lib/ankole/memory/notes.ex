defmodule Ankole.Memory.Notes do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Ankole.Ecto.UUIDv7
  alias Ankole.Memory.Config
  alias Ankole.Memory.Note
  alias Ankole.Repo

  @type note_result :: {:ok, Note.t()} | {:error, term()}

  @doc false
  @spec list_notes(String.t(), String.t()) :: [map()]
  def list_notes(agent_uid, signal_channel_id)
      when is_binary(agent_uid) and is_binary(signal_channel_id) do
    agent_uid = String.downcase(agent_uid)

    Note
    |> where([note], note.agent_uid == ^agent_uid)
    |> where([note], note.signal_channel_id == ^signal_channel_id)
    |> order_by([note], asc: note.inserted_at, asc: note.id)
    |> Repo.all()
    |> Enum.map(&note_projection/1)
  end

  @doc false
  @spec notes_for_context(String.t(), String.t() | nil) :: [map()]
  def notes_for_context(_agent_uid, nil), do: []

  def notes_for_context(agent_uid, signal_channel_id)
      when is_binary(agent_uid) and is_binary(signal_channel_id) do
    case Config.notes(agent_uid) do
      {:ok, %{"enabled" => true}} -> list_notes(agent_uid, signal_channel_id)
      _value -> []
    end
  end

  @doc false
  @spec save_note(String.t(), String.t(), String.t(), map()) :: note_result()
  def save_note(agent_uid, signal_channel_id, content, source \\ %{})
      when is_binary(agent_uid) and is_binary(signal_channel_id) and is_binary(content) and
             is_map(source) do
    agent_uid = String.downcase(agent_uid)

    with {:ok, config} <- Config.notes(agent_uid),
         :ok <- notes_enabled(config),
         :ok <- note_content_allowed(content, config) do
      Repo.transact(fn repo ->
        # The quota is an agent-and-channel invariant, but counting then inserting is not atomic by
        # itself. A transaction-scoped advisory lock serializes only writers competing for this scope.
        lock_note_scope(repo, agent_uid, signal_channel_id)

        case note_count_allows_insert(repo, agent_uid, signal_channel_id, config) do
          :ok ->
            %Note{}
            |> Note.changeset(%{
              agent_uid: agent_uid,
              signal_channel_id: signal_channel_id,
              content: content,
              source: source
            })
            |> repo.insert()
            |> case do
              {:ok, note} -> {:ok, note}
              {:error, changeset} -> {:error, changeset}
            end

          {:error, reason} ->
            {:error, reason}
        end
      end)
      |> case do
        {:ok, %Note{} = note} -> {:ok, note}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  @spec update_note(String.t(), String.t(), String.t()) :: note_result()
  def update_note(agent_uid, note_id, content)
      when is_binary(agent_uid) and is_binary(note_id) and is_binary(content) do
    update_note(agent_uid, nil, note_id, content)
  end

  @doc false
  @spec update_note(String.t(), String.t() | nil, String.t(), String.t()) :: note_result()
  def update_note(agent_uid, signal_channel_id, note_id, content)
      when is_binary(agent_uid) and is_binary(note_id) and is_binary(content) do
    agent_uid = String.downcase(agent_uid)

    with {:ok, config} <- Config.notes(agent_uid),
         :ok <- notes_enabled(config),
         :ok <- note_content_allowed(content, config),
         %Note{} = note <- get_agent_note(agent_uid, note_id),
         :ok <- note_in_channel(note, signal_channel_id) do
      note
      |> Note.changeset(%{content: content})
      |> Repo.update()
    else
      nil -> {:error, :memory_note_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec forget_note(String.t(), String.t()) :: {:ok, Note.t()} | {:error, term()}
  def forget_note(agent_uid, note_id) when is_binary(agent_uid) and is_binary(note_id) do
    forget_note(agent_uid, nil, note_id)
  end

  @doc false
  @spec forget_note(String.t(), String.t() | nil, String.t()) ::
          {:ok, Note.t()} | {:error, term()}
  def forget_note(agent_uid, signal_channel_id, note_id)
      when is_binary(agent_uid) and is_binary(note_id) do
    agent_uid = String.downcase(agent_uid)

    with %Note{} = note <- get_agent_note(agent_uid, note_id),
         :ok <- note_in_channel(note, signal_channel_id) do
      Repo.delete(note)
    else
      nil -> {:error, :memory_note_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp notes_enabled(%{"enabled" => true}), do: :ok
  defp notes_enabled(_config), do: {:error, :memory_notes_disabled}

  defp note_content_allowed(content, %{"max_content_chars" => max_chars}) do
    cond do
      String.trim(content) == "" -> {:error, :memory_note_empty}
      String.length(content) > max_chars -> {:error, :memory_note_too_long}
      true -> :ok
    end
  end

  defp lock_note_scope(repo, agent_uid, signal_channel_id) do
    repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [
      "memory_notes:#{agent_uid}:#{signal_channel_id}"
    ])
  end

  defp note_count_allows_insert(repo, agent_uid, signal_channel_id, %{
         "max_notes_per_channel" => max_notes
       }) do
    count =
      Note
      |> where([note], note.agent_uid == ^agent_uid)
      |> where([note], note.signal_channel_id == ^signal_channel_id)
      |> repo.aggregate(:count)

    case count < max_notes do
      true -> :ok
      false -> {:error, :memory_note_limit_reached}
    end
  end

  defp get_agent_note(agent_uid, note_id) do
    with {:ok, note_id} <- UUIDv7.cast(note_id) do
      Note
      |> where([note], note.agent_uid == ^agent_uid)
      |> where([note], note.id == ^note_id)
      |> Repo.one()
    else
      :error -> nil
    end
  end

  defp note_in_channel(_note, nil), do: :ok

  defp note_in_channel(%Note{signal_channel_id: signal_channel_id}, signal_channel_id), do: :ok
  defp note_in_channel(%Note{}, _signal_channel_id), do: {:error, :memory_note_not_found}

  defp note_projection(%Note{} = note) do
    %{
      "id" => note.id,
      "agent_uid" => note.agent_uid,
      "channel_id" => note.signal_channel_id,
      "content" => note.content,
      "source" => note.source || %{},
      "created_at" => datetime(note.inserted_at),
      "updated_at" => datetime(note.updated_at)
    }
  end

  defp datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp datetime(_value), do: nil
end
