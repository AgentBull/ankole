defmodule Ankole.IdentityProviders.SiteSources do
  @moduledoc "Trusted site authentication sources selected by the source build."

  @callback authenticate(term()) ::
              {:ok, %{subject_id: String.t(), auth_time: integer() | nil}} | {:error, term()}
  @callback login_path() :: String.t()
  @callback display_name() :: String.t()
  @callback fresh_authentication?() :: boolean()

  def declarations, do: Application.get_env(:ankole, :site_identity_sources, [])
  def registered?(id), do: is_binary(id) and List.keymember?(declarations(), id, 0)

  def providers do
    Enum.map(declarations(), fn {id, module} ->
      %{
        "provider_id" => id,
        "adapter_id" => id,
        "plugin_id" => nil,
        "kind" => "site",
        "display_name" => module.display_name(),
        "login_path" => module.login_path(),
        "fresh_authentication" => module.fresh_authentication?()
      }
    end)
  end

  def authenticate(id, proof) do
    with {:ok, module} <- fetch(id),
         {:ok, %{subject_id: subject, auth_time: time} = identity} <- module.authenticate(proof),
         true <- is_binary(subject) and subject != "" and (is_nil(time) or is_integer(time)) do
      {:ok, identity}
    else
      false -> {:error, :invalid_authentication}
      {:error, _} = error -> error
      _ -> {:error, :invalid_authentication}
    end
  end

  def fetch(id) do
    case List.keyfind(declarations(), id, 0) do
      {^id, module} -> {:ok, module}
      nil -> {:error, :identity_provider_not_allowed}
    end
  end

  def validate! do
    ids = Enum.map(declarations(), &elem(&1, 0))
    if length(ids) != length(Enum.uniq(ids)), do: raise("Duplicate site identity source ID")

    Enum.each(declarations(), fn {id, module} ->
      unless is_binary(id) and
               match?({:ok, ^id}, Ankole.IdentityProviders.normalize_provider_id(id)) and
               Code.ensure_loaded?(module) and
               Enum.all?(
                 [authenticate: 1, login_path: 0, display_name: 0, fresh_authentication?: 0],
                 fn {function, arity} -> function_exported?(module, function, arity) end
               ) do
        raise "Invalid site identity source #{inspect(id)}"
      end
    end)

    :ok
  end
end
