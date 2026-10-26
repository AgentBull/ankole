defmodule Ankole.ActorRef do
  @moduledoc """
  Stable attribution to a Principal, including its tenant after deletion.
  """

  # The JSON:API serializer encodes attribute values with Jason.
  @derive {Jason.Encoder, only: [:tenant_id, :uid]}
  @enforce_keys [:tenant_id, :uid]
  defstruct [:tenant_id, :uid]

  @type t :: %__MODULE__{tenant_id: Ecto.UUID.t(), uid: String.t()}

  def from_actor(%Ankole.AuthZ.Actor{principal: principal}), do: from_principal(principal)

  def from_principal(%{tenant_id: tenant_id, uid: uid}) do
    {:ok, reference} = cast(%__MODULE__{tenant_id: tenant_id, uid: uid})
    reference
  end

  def from_writer(:system, _tenant_id, opts), do: Keyword.get(opts, :author)

  def from_writer(uid, tenant_id, _opts) when is_binary(uid),
    do: from_principal(%{tenant_id: tenant_id, uid: uid})

  def cast(%__MODULE__{tenant_id: tenant_id, uid: uid}) do
    with {:ok, tenant_id} <- Ecto.UUID.cast(tenant_id),
         {:ok, ^uid} <- Ankole.PrincipalKey.normalize(uid) do
      {:ok, %__MODULE__{tenant_id: tenant_id, uid: uid}}
    else
      _ -> :error
    end
  end

  def cast("ankole:" <> value) do
    case String.split(value, ":principal/", parts: 2) do
      [tenant_id, uid] -> cast(%__MODULE__{tenant_id: tenant_id, uid: uid})
      _ -> :error
    end
  end

  def cast(_), do: :error
end

defimpl String.Chars, for: Ankole.ActorRef do
  def to_string(%{tenant_id: tenant_id, uid: uid}),
    do: "ankole:#{tenant_id}:principal/#{uid}"
end
