defmodule BullX.Gateway.Moderation do
  @moduledoc false

  alias BullX.Gateway.{InboundError, SourceConfig}

  @callback moderate(SourceConfig.t(), map()) ::
              {:ok, map()} | {:ok, map(), [String.t()]} | {:deny, String.t(), map()}

  @spec moderate(SourceConfig.t(), map()) ::
          {:ok, map(), [String.t()], boolean()} | {:error, InboundError.t()}
  def moderate(%SourceConfig{} = source, input) do
    source
    |> module()
    |> safe_moderate(source, input)
  end

  defp module(_source) do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(:moderation, BullX.Gateway.Moderation.Noop)
  end

  defp safe_moderate(module, source, input) do
    case module.moderate(source, input) do
      {:ok, ^input} ->
        {:ok, input, [], false}

      {:ok, moderated} when is_map(moderated) ->
        {:ok, moderated, [], moderated["content"] != input["content"]}

      {:ok, moderated, flags} when is_map(moderated) and is_list(flags) ->
        {:ok, moderated, Enum.map(flags, &to_string/1), moderated["content"] != input["content"]}

      {:deny, message, details} ->
        {:error, InboundError.new(:policy_denied, message, details)}

      _other ->
        {:error, InboundError.new(:policy_denied, "invalid moderation hook result")}
    end
  catch
    :exit, reason ->
      {:error,
       InboundError.new(:policy_denied, "moderation hook exited", %{reason: inspect(reason)})}

    kind, reason ->
      {:error,
       InboundError.new(:policy_denied, "moderation hook failed", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end
end

defmodule BullX.Gateway.Moderation.Noop do
  @moduledoc false

  @behaviour BullX.Gateway.Moderation

  @impl true
  def moderate(_source, input), do: {:ok, input}
end
