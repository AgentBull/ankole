defmodule DingTalkOpenAPI.Card do
  @moduledoc """
  DingTalk interactive-card and AI-card instance operations (new domain).

  Cards are created from a template (`cardTemplateId`, built on the card
  platform) as an instance keyed by a caller-generated `outTrackId`, which makes
  create/deliver idempotent and replay-safe. Streaming markdown updates go
  through `streaming_update/2` with `isFull: true` (the platform requires full
  overwrite for markdown variables); the terminal large structure goes through
  `update_instance/2`.

  Each function takes the fully-shaped params map and posts/puts it verbatim, so
  the adapter owns the exact `cardData` / `openSpaceId` shape.
  """

  alias DingTalkOpenAPI.{Client, Error}

  @instances_path "/v1.0/card/instances"
  @deliver_path "/v1.0/card/instances/deliver"
  @create_and_deliver_path "/v1.0/card/instances/createAndDeliver"
  @streaming_path "/v1.0/card/streaming"

  @doc "Create a card instance. `params` carries `cardTemplateId`, `outTrackId`, `cardData`, `callbackType`, and an open-space model."
  @spec create_instance(Client.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def create_instance(%Client{} = client, params) when is_map(params) do
    DingTalkOpenAPI.post(client, @instances_path, body: params)
  end

  @doc "Deliver a created card instance to a space. `params` carries `outTrackId`, `openSpaceId`, and a deliver model."
  @spec deliver_instance(Client.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def deliver_instance(%Client{} = client, params) when is_map(params) do
    DingTalkOpenAPI.post(client, @deliver_path, body: params)
  end

  @doc "Create and deliver a card instance in one call."
  @spec create_and_deliver(Client.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def create_and_deliver(%Client{} = client, params) when is_map(params) do
    DingTalkOpenAPI.post(client, @create_and_deliver_path, body: params)
  end

  @doc "Full-overwrite update of a card instance's `cardData`. `params` carries `outTrackId` and `cardData`."
  @spec update_instance(Client.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def update_instance(%Client{} = client, params) when is_map(params) do
    DingTalkOpenAPI.put(client, @instances_path, body: params)
  end

  @doc """
  Streaming update of a card variable. `params` carries `outTrackId`, `guid`
  (idempotency key), `key` (variable name), `content`, `isFull`, `isFinalize`,
  `isError`.
  """
  @spec streaming_update(Client.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def streaming_update(%Client{} = client, params) when is_map(params) do
    DingTalkOpenAPI.put(client, @streaming_path, body: params)
  end
end
