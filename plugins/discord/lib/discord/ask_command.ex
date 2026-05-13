defmodule Discord.AskCommand do
  @moduledoc """
  Discord-specific `/ask` flow concerns that sit between the account gate and
  the Gateway publish step.

  The handler responsibilities are:

  - Send an ephemeral interaction acknowledgement before publishing, so
    Discord's 3-second interaction-response window is satisfied.
  - Yield the unchanged mapped value for non-`/ask` events.

  Thread creation and `scope_id` rewriting live in `Discord.ThreadOwnership`;
  the channel publish pipeline runs `ThreadOwnership.maybe_auto_thread/2`
  after this acknowledgement step.
  """

  alias Discord.{Error, Source}

  @ephemeral_flag 64

  @doc """
  Sends an ephemeral acknowledgement for the underlying `INTERACTION_CREATE`
  if `mapped.interaction` is present; otherwise returns `mapped` unchanged.

  Returns `{:ok, mapped}` on success (mapped unchanged), or `{:error, error}`
  if the acknowledgement fails. The acknowledgement must succeed before
  thread creation, because thread creation is observably slower than
  Discord's 3-second response window.
  """
  @spec acknowledge_if_interaction(map(), Source.t()) :: {:ok, map()} | {:error, map()}
  def acknowledge_if_interaction(%{interaction: nil} = mapped, _source), do: {:ok, mapped}

  def acknowledge_if_interaction(%{interaction: interaction} = mapped, %Source{} = source)
      when not is_nil(interaction) do
    response = %{
      type: 4,
      data: %{
        content: BullX.I18n.t("gateway.discord.ask.accepted"),
        flags: @ephemeral_flag
      }
    }

    Source.with_bot(source, fn ->
      source.interaction_api.create_response(interaction, response)
    end)
    |> case do
      :ok ->
        :telemetry.execute(
          [:bullx, :discord, :ask, :acknowledged],
          %{count: 1},
          %{channel_id: source.channel_id}
        )

        {:ok, mapped}

      {:ok, _result} ->
        :telemetry.execute(
          [:bullx, :discord, :ask, :acknowledged],
          %{count: 1},
          %{channel_id: source.channel_id}
        )

        {:ok, mapped}

      {:error, error} ->
        {:error, Error.map(error)}

      other ->
        {:error, Error.map(other)}
    end
  end

  def acknowledge_if_interaction(mapped, _source), do: {:ok, mapped}
end
