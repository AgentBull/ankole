defmodule BullX.EventBus.TargetSession do
  @moduledoc """
  Weak runtime TargetSession row and lifecycle helpers.

  The row identifies one execution lane. It is not business truth.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias BullX.EventBus.TargetSessionEntry
  alias BullX.Repo

  @primary_key {:id, BullX.Ecto.UUIDv7, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @statuses [:active, :closed, :failed]
  @target_types [:ai_agent, :workflow, :command, :work, :blackhole]

  @type status :: :active | :closed | :failed
  @type t :: %__MODULE__{}

  schema "target_sessions" do
    field :event_routing_rule_id, :binary_id
    field :target_type, Ecto.Enum, values: @target_types
    field :target_ref, :string
    field :scope_key, :string
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :oban_job_id, :integer
    field :last_processed_entry_seq, :integer, default: 0
    field :terminal_reason, :string

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :event_routing_rule_id,
      :target_type,
      :target_ref,
      :scope_key,
      :status,
      :oban_job_id,
      :last_processed_entry_seq,
      :terminal_reason
    ])
    |> validate_required([
      :event_routing_rule_id,
      :target_type,
      :target_ref,
      :scope_key,
      :status,
      :last_processed_entry_seq
    ])
    |> unique_constraint(
      [:event_routing_rule_id, :target_type, :target_ref, :scope_key],
      name: :target_sessions_active_reuse_key_index
    )
  end

  @spec close(String.t()) :: :ok | {:error, term()}
  def close(target_session_id) when is_binary(target_session_id) do
    case Process.get({__MODULE__, :current_target_session_id}) do
      ^target_session_id ->
        Process.put({__MODULE__, :close_requested}, true)
        :ok

      _other ->
        attempt_close(target_session_id)
    end
  end

  @spec fail(String.t(), term()) :: :ok | {:error, term()}
  def fail(target_session_id, reason) when is_binary(target_session_id) do
    safe_reason = safe_terminal_reason(reason)

    Repo.transaction(fn ->
      case Repo.one(lock_session_query(target_session_id)) do
        nil ->
          Repo.rollback(:not_found)

        %__MODULE__{status: :active} = session ->
          session
          |> changeset(%{status: :failed, terminal_reason: safe_reason})
          |> Repo.update()
          |> case do
            {:ok, _session} -> :ok
            {:error, changeset} -> Repo.rollback(changeset)
          end

        %__MODULE__{} ->
          :ok
      end
    end)
    |> unwrap_transaction()
  end

  @spec attempt_close(String.t()) :: :ok | {:error, term()}
  def attempt_close(target_session_id) when is_binary(target_session_id) do
    Repo.transaction(fn ->
      with %__MODULE__{} = session <- Repo.one(lock_session_query(target_session_id)),
           :active <- session.status,
           false <- pending_entries?(session) do
        session
        |> changeset(%{status: :closed})
        |> Repo.update()
        |> case do
          {:ok, _session} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      else
        nil -> Repo.rollback(:not_found)
        status when status in [:closed, :failed] -> :ok
        true -> :ok
      end
    end)
    |> unwrap_transaction()
  end

  @spec safe_terminal_reason(term()) :: String.t()
  def safe_terminal_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  def safe_terminal_reason(reason) when is_binary(reason), do: String.slice(reason, 0, 200)

  def safe_terminal_reason(reason),
    do: reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 200)

  defp pending_entries?(%__MODULE__{} = session) do
    TargetSessionEntry
    |> where([e], e.target_session_id == ^session.id)
    |> where([e], e.entry_seq > ^session.last_processed_entry_seq)
    |> limit(1)
    |> Repo.exists?()
  end

  defp lock_session_query(target_session_id) do
    __MODULE__
    |> where([s], s.id == ^target_session_id)
    |> lock("FOR UPDATE")
  end

  defp unwrap_transaction({:ok, value}), do: value
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
