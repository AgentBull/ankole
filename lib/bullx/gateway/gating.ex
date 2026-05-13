defmodule BullX.Gateway.Gating do
  @moduledoc false

  alias BullX.Gateway.{InboundError, SourceConfig}

  @callback check(SourceConfig.t(), map()) ::
              :allow | {:allow_with_flags, [String.t()]} | {:deny, String.t(), map()}

  @spec check(SourceConfig.t(), map()) :: {:ok, map(), [String.t()]} | {:error, InboundError.t()}
  def check(%SourceConfig{} = source, input) do
    source
    |> module()
    |> safe_check(source, input)
  end

  defp module(_source) do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(:gating, BullX.Gateway.Gating.AllowAll)
  end

  defp safe_check(module, source, input) do
    case module.check(source, input) do
      :allow ->
        {:ok, input, []}

      {:allow_with_flags, flags} when is_list(flags) ->
        {:ok, input, Enum.map(flags, &to_string/1)}

      {:deny, message, details} ->
        {:error, InboundError.new(:policy_denied, message, details)}

      _other ->
        {:error, InboundError.new(:policy_denied, "invalid gating hook result")}
    end
  catch
    :exit, reason ->
      {:error, InboundError.new(:policy_denied, "gating hook exited", %{reason: inspect(reason)})}

    kind, reason ->
      {:error,
       InboundError.new(:policy_denied, "gating hook failed", %{
         kind: kind,
         reason: inspect(reason)
       })}
  end
end

defmodule BullX.Gateway.Gating.AllowAll do
  @moduledoc false

  @behaviour BullX.Gateway.Gating

  @impl true
  def check(_source, _input), do: :allow
end
