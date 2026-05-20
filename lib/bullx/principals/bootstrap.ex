defmodule BullX.Principals.Bootstrap do
  @moduledoc false

  use Task

  require Logger

  alias BullX.Principals
  alias BullX.Repo

  def start_link(_opts), do: Task.start_link(__MODULE__, :run, [])

  def child_spec(opts) do
    opts
    |> super()
    |> Map.put(:restart, :transient)
  end

  def run do
    case authn_tables_ready?() do
      true ->
        maybe_create_or_refresh_bootstrap_activation_code()

      false ->
        Logger.warning("BullX.Principals bootstrap skipped because Principal tables do not exist")
    end
  end

  defp maybe_create_or_refresh_bootstrap_activation_code do
    cond do
      not BullX.Principals.AuthN.setup_required?() ->
        :ok

      BullX.Principals.AuthN.bootstrap_activation_code_consumed?() ->
        :ok

      true ->
        ensure_bootstrap_activation_code()
    end
  end

  # The plaintext code is logged when the operator opens /setup/sessions/new
  # (see BullXWeb.SetupSessionController), not here — boot only guarantees a
  # pending code exists so the home page can route into the setup flow.
  defp ensure_bootstrap_activation_code do
    case Principals.create_or_refresh_bootstrap_activation_code() do
      {:ok, _result} ->
        :ok

      {:error, reason} when reason in [:bootstrap_not_required, :bootstrap_already_consumed] ->
        :ok

      {:error, reason} ->
        raise "BullX.Principals bootstrap activation code creation failed: #{inspect(reason)}"
    end
  end

  defp authn_tables_ready? do
    query = """
    SELECT
      EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'principals'
      ),
      EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = current_schema()
          AND table_name = 'activation_codes'
      )
    """

    %{rows: [[principals, activation_codes]]} = Ecto.Adapters.SQL.query!(Repo, query, [])
    principals and activation_codes
  end
end
