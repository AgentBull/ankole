defmodule BullX.Config.SystemBinding do
  @moduledoc """
  Skogsra binding for environment variables with BullX validation.

  This binding keeps OS environment values as the highest-trust source for
  startup secrets and deployment settings while still applying the same Zoi
  validation used for database-backed runtime config.
  """

  use Skogsra.Binding

  @impl Skogsra.Binding
  def get_env(%Skogsra.Env{} = env, _state) do
    os_var = os_var_name(env)

    case System.get_env(os_var) do
      nil ->
        nil

      raw ->
        case BullX.Config.Validation.validate_runtime_raw(env, raw) do
          :ok -> {:ok, raw}
          {:error, _} -> nil
        end
    end
  end

  defp os_var_name(env) do
    namespace = Skogsra.Env.gen_namespace(env)
    app_name = Skogsra.Env.gen_app_name(env)
    keys = Skogsra.Env.gen_keys(env)

    "#{namespace}#{app_name}_#{keys}"
  end
end
