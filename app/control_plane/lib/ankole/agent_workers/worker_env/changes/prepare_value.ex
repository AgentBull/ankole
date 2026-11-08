defmodule Ankole.AgentWorkers.WorkerEnv.Changes.PrepareValue do
  @moduledoc false
  use Ash.Resource.Change

  alias Ankole.AgentWorkers.WorkerEnv

  @impl true
  def change(changeset, opts, _context) do
    scope = Ash.Changeset.get_attribute(changeset, :scope)
    name = Ash.Changeset.get_attribute(changeset, :name)
    attrs = Ash.Changeset.get_argument(changeset, :input)
    inherit_existing? = Keyword.get(opts, :inherit_existing?, true)

    with :ok <- WorkerEnv.validate_name(name),
         existing =
           if(inherit_existing?,
             do: WorkerEnv.effective_row(scope, name),
             else: WorkerEnv.own_row(scope, name)
           ),
         {:ok, secret} <- custom_secret(attrs, existing),
         {:ok, description} <- custom_description(attrs, existing),
         {:ok, value} <-
           custom_stored_value(attrs, existing, secret, scope, name, inherit_existing?) do
      changeset
      |> Ash.Changeset.force_change_attribute(:secret, secret)
      |> Ash.Changeset.force_change_attribute(:description, description)
      |> Ash.Changeset.force_change_attribute(:value, value)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(
          changeset,
          Ankole.Errors.Invalid.Rejected.exception(reason: reason)
        )
    end
  end

  defp custom_stored_value(attrs, existing, secret, scope, name, allow_unseal_without_value?) do
    case Map.fetch(attrs, "value") do
      {:ok, nil} when existing != nil ->
        preserve_custom_stored_value(
          existing,
          secret,
          scope,
          name,
          allow_unseal_without_value?
        )

      {:ok, value} when is_binary(value) ->
        if Regex.match?(~r/\S/, value) do
          stored_value(value, secret, scope, name)
        else
          {:error, :invalid_worker_env_value}
        end

      {:ok, _value} ->
        {:error, :invalid_worker_env_value}

      :error ->
        preserve_custom_stored_value(
          existing,
          secret,
          scope,
          name,
          allow_unseal_without_value?
        )
    end
  end

  defp preserve_custom_stored_value(nil, _secret, _scope, _name, _allow_unseal_without_value?),
    do: {:error, :invalid_worker_env_value}

  defp preserve_custom_stored_value(
         %{secret: secret, value: value, scope: scope, name: name},
         secret,
         scope,
         name,
         _allow_unseal_without_value?
       ),
       do: {:ok, value}

  defp preserve_custom_stored_value(
         %{secret: true},
         false,
         _scope,
         _name,
         false
       ),
       do: {:error, :invalid_worker_env_value}

  defp preserve_custom_stored_value(
         %{scope: _} = existing,
         secret,
         scope,
         name,
         _allow_unseal_without_value?
       ) do
    with {:ok, value} <- WorkerEnv.row_value(existing) do
      stored_value(value, secret, scope, name)
    end
  end

  # Flipping secret on an existing console row re-seals or re-exposes on this write;
  # Pod `:put_own` requires a fresh value when clearing `secret` on a stored secret,
  # and an absent or null flag keeps the stored state instead of silently decrypting.
  defp custom_secret(attrs, existing) do
    case Map.fetch(attrs, "secret") do
      {:ok, nil} -> {:ok, if(existing, do: existing.secret, else: false)}
      {:ok, secret} when is_boolean(secret) -> {:ok, secret}
      {:ok, _secret} -> {:error, :invalid_worker_env_secret}
      :error -> {:ok, if(existing, do: existing.secret, else: false)}
    end
  end

  defp custom_description(attrs, existing) do
    case Map.fetch(attrs, "description") do
      {:ok, nil} -> {:ok, nil}
      {:ok, description} when is_binary(description) -> {:ok, description}
      {:ok, _description} -> {:error, :invalid_worker_env_description}
      :error -> {:ok, if(existing, do: existing.description, else: nil)}
    end
  end

  defp stored_value(value, false, _scope, _name), do: {:ok, value}

  defp stored_value(value, true, scope, name),
    do: Ankole.SecretKeyBase.seal(value, "worker_env", [scope, name])
end
