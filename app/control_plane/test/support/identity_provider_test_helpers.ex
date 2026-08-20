defmodule Ankole.IdentityProviderTestHelpers do
  @moduledoc """
  Rewrites the active lark identity-provider declaration in the running plugin
  registry and restores the original registry state when the test exits.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @spec update_lark_identity_declaration((map() -> map())) :: :ok
  def update_lark_identity_declaration(fun) when is_function(fun, 1) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)

    :sys.replace_state(Ankole.Plugins.Registry, fn state ->
      update_in(state.active["lark-adapter"].adapter_declarations, fn declarations ->
        Enum.map(declarations, fn declaration ->
          case Map.get(declaration, :contract_id) do
            "principals.identity_provider" -> fun.(declaration)
            _other -> declaration
          end
        end)
      end)
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end
end
