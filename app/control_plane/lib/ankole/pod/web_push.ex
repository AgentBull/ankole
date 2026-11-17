defmodule Ankole.Pod.WebPush do
  @moduledoc """
  Delivers Pod notifications to the browsers that a Human subscribed with Web Push.

  A committed room message schedules `Ankole.Pod.Jobs.DeliverWebPush` a few
  seconds later. The delay lets a Human who is reading the room mark it read
  first, so `Ankole.Conversations.Notifications.claim/1` leaves them out and
  their browser shows no notification. Messages that arrive while a delivery
  waits join it, and the delivery sends only the room's newest message.

  Each payload is encrypted for one subscription with RFC 8291 (`aes128gcm`),
  and RFC 8292 VAPID authenticates the site to the push service. Ankole
  derives the VAPID key pair from the endpoint's `secret_key_base`, so the
  installation needs no stored key. A browser compares the public key with the
  one its subscription uses and subscribes again when they differ.
  """

  require Ash.Query

  alias Ankole.AuthZ.Actor
  alias Ankole.Pod.WebPushSubscription

  @delay_seconds 5
  @ttl_seconds 86_400
  @record_size 4096
  @max_body 240
  # The order of the P-256 group; a private scalar lies in [1, n - 1].
  @p256_order 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

  @spec public_key() :: String.t()
  def public_key do
    {public, _private} = vapid_keys()
    b64(public)
  end

  @spec subscribe(Actor.t(), map()) :: {:ok, %{subscribed: true}} | {:error, term()}
  def subscribe(%Actor{} = actor, %{endpoint: endpoint, p256dh: p256dh, auth: auth} = attrs) do
    with :ok <- validate_endpoint(endpoint),
         {:ok, <<4, _::binary-size(64)>> = key} <- decode(p256dh),
         true <- on_curve?(key),
         {:ok, <<_::binary-size(16)>>} <- decode(auth),
         {:ok, _} <-
           Ankole.Ash.create(WebPushSubscription, :put, %{
             endpoint: endpoint,
             principal_uid: Actor.uid(actor),
             p256dh: p256dh,
             auth: auth,
             user_agent: attrs |> Map.get(:userAgent) |> truncate(512)
           }) do
      {:ok, %{subscribed: true}}
    else
      {:error, :invalid_endpoint} = error -> error
      # A malformed key or a stored row that rejects the values both mean an unusable subscription.
      _ -> {:error, :invalid_subscription}
    end
  end

  @spec unsubscribe(Actor.t(), String.t()) :: {:ok, %{subscribed: false}} | {:error, term()}
  def unsubscribe(%Actor{} = actor, endpoint) when is_binary(endpoint) do
    uid = Actor.uid(actor)

    with {:ok, _} <-
           WebPushSubscription
           |> Ash.Query.filter(endpoint == ^endpoint and principal_uid == ^uid)
           |> Ankole.Ash.destroy_where(:remove),
         do: {:ok, %{subscribed: false}}
  end

  @doc "Schedules a delivery for a room after a message in it commits."
  @spec enqueue(Ecto.UUID.t()) :: :ok
  def enqueue(conversation_id) do
    # The message has already committed, so a failed insert costs only this notification.
    case %{conversation_id: conversation_id}
         |> Ankole.Pod.Jobs.DeliverWebPush.new(schedule_in: @delay_seconds)
         |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, _reason} ->
        Ankole.Logging.warning(
          "pod.web_push.enqueue_failed",
          "a push delivery could not be scheduled",
          %{}
        )
    end

    :ok
  end

  @doc """
  Sends the room's newest notifiable message to every Human whom it notifies.

  `:settled_before` holds back a message that committed later and returns
  `{:snooze, seconds}`; `:req_options` adds Req options to each push request,
  such as a test plug.
  """
  @spec deliver(Ecto.UUID.t(), keyword()) :: :ok | {:snooze, pos_integer()}
  def deliver(conversation_id, opts \\ []) do
    case Ankole.Conversations.claim_notifications(conversation_id,
           settled_before: opts[:settled_before]
         ) do
      {:wait, seconds} ->
        {:snooze, seconds}

      {:ok, %{recipients: [_ | _] = uids} = claim} ->
        uids
        |> subscriptions()
        |> push_all(claim, Keyword.get(opts, :req_options, []))

      _nothing_to_send ->
        :ok
    end
  end

  defp subscriptions(uids) do
    WebPushSubscription |> Ash.Query.filter(principal_uid in ^uids) |> Ankole.Ash.read!()
  end

  defp push_all([], _claim, _req_options), do: :ok

  defp push_all(subscriptions, claim, req_options) do
    payload = claim |> payload() |> Ankole.JSON.encode!()
    keys = vapid_keys()
    topic = String.slice(Ankole.Kernel.uuid_shorten(claim.conversation.id), 0, 32)

    Enum.each(subscriptions, fn subscription ->
      # One unusable subscription must not cost the others their notification.
      try do
        send_push(subscription, payload, topic, keys, req_options)
      rescue
        error ->
          Ankole.Logging.warning(
            "pod.web_push.failed",
            "a push notification could not be sent",
            %{error_class: inspect(error.__struct__)}
          )
      end
    end)
  end

  @doc "How long a delivery waits after the newest message, so a Human who is reading the room can mark it read."
  def delay_seconds, do: @delay_seconds

  @doc false
  def payload(%{conversation: conversation, message: message, decision?: decision?}) do
    author = message.author_display_name || conversation.title
    text = message.text |> to_string() |> String.trim()

    text =
      if text == "" and decision?,
        do: Ankole.I18n.t("conversations.delivery.reply.needs_input"),
        else: text

    {title, body} =
      if conversation.dm_colleague_uid,
        do: {author, text},
        else: {conversation.title, if(text == "", do: author, else: author <> ": " <> text)}

    %{
      title: title,
      body: truncate(body, @max_body),
      tag: conversation.id,
      url: AnkoleWeb.PodURL.conversation_path(conversation.id),
      decision: decision?
    }
  end

  defp send_push(subscription, payload, topic, keys, req_options) do
    with {:ok, user_public} <- decode(subscription.p256dh),
         {:ok, auth} <- decode(subscription.auth) do
      body =
        encrypt(
          payload,
          user_public,
          auth,
          :crypto.generate_key(:ecdh, :prime256v1),
          :crypto.strong_rand_bytes(16)
        )

      proxy = Ankole.EgressProxy.req_options(subscription.endpoint)
      connect = Keyword.merge([timeout: 5000], Keyword.get(proxy, :connect_options, []))

      result =
        Req.post(
          subscription.endpoint,
          Keyword.merge(proxy,
            body: body,
            headers: [
              {"authorization", vapid_authorization(subscription.endpoint, keys)},
              {"ttl", Integer.to_string(@ttl_seconds)},
              {"content-encoding", "aes128gcm"},
              {"content-type", "application/octet-stream"},
              {"urgency", "high"},
              {"topic", topic}
            ],
            connect_options: connect,
            retry: false,
            redirect: false,
            receive_timeout: 5000,
            decode_body: false
          )
          |> Keyword.merge(req_options)
        )

      case result do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        # The browser dropped this subscription, so Ankole forgets it.
        {:ok, %{status: status}} when status in [404, 410] ->
          WebPushSubscription
          |> Ash.Query.filter(endpoint == ^subscription.endpoint)
          |> Ankole.Ash.destroy_where(:remove)

        {:ok, %{status: status}} ->
          Ankole.Logging.warning(
            "pod.web_push.rejected",
            "the push service rejected a notification",
            %{
              status: status,
              host: URI.parse(subscription.endpoint).host
            }
          )

        {:error, error} ->
          Ankole.Logging.warning(
            "pod.web_push.failed",
            "a push notification could not be sent",
            %{
              error_class: inspect(error.__struct__),
              host: URI.parse(subscription.endpoint).host
            }
          )
      end
    end
  end

  @doc false
  # RFC 8291 section 3: one aes128gcm record whose header carries the sender's public key.
  def encrypt(plaintext, user_public, auth, {sender_public, sender_private}, salt) do
    secret = :crypto.compute_key(:ecdh, user_public, sender_private, :prime256v1)
    key_info = "WebPush: info" <> <<0>> <> user_public <> sender_public
    ikm = hmac(hmac(auth, secret), key_info <> <<1>>)
    prk = hmac(salt, ikm)
    <<key::binary-size(16), _::binary>> = hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
    <<nonce::binary-size(12), _::binary>> = hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_128_gcm, key, nonce, plaintext <> <<2>>, <<>>, true)

    salt <>
      <<@record_size::unsigned-32, byte_size(sender_public)::8>> <>
      sender_public <> ciphertext <> tag
  end

  @doc false
  # RFC 8292: an ES256 JWT for the push service's origin plus the public key.
  def vapid_authorization(endpoint, {public, private}, now \\ System.system_time(:second)) do
    %URI{scheme: scheme, host: host, port: port} = URI.parse(endpoint)
    audience = URI.to_string(%URI{scheme: scheme, host: host, port: port})
    # Apple's push service requires an https or mailto subject.
    subject =
      AnkoleWeb.Endpoint.url()
      |> URI.parse()
      |> Map.put(:scheme, "https")
      |> Map.put(:port, nil)
      |> URI.to_string()

    header = b64(Ankole.JSON.encode!(%{typ: "JWT", alg: "ES256"}))
    claims = b64(Ankole.JSON.encode!(%{aud: audience, exp: now + 12 * 3600, sub: subject}))
    input = header <> "." <> claims
    der = :crypto.sign(:ecdsa, :sha256, input, [private, :prime256v1])
    {:"ECDSA-Sig-Value", r, s} = :public_key.der_decode(:"ECDSA-Sig-Value", der)
    "vapid t=" <> input <> "." <> b64(<<r::256, s::256>>) <> ", k=" <> b64(public)
  end

  defp vapid_keys do
    {:ok, secret} = Ankole.SecretKeyBase.fetch()
    seed = :crypto.hash(:sha256, Ankole.Kernel.derive_key(secret, "web_push", "vapid"))
    scalar = rem(:binary.decode_unsigned(seed), @p256_order - 1) + 1
    :crypto.generate_key(:ecdh, :prime256v1, <<scalar::256>>)
  end

  # A key that is not a P-256 point would make every later encryption for it raise.
  defp on_curve?(key) do
    {_public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    is_binary(:crypto.compute_key(:ecdh, key, private, :prime256v1))
  rescue
    _error -> false
  end

  defp validate_endpoint(endpoint) when is_binary(endpoint) and byte_size(endpoint) <= 2048 do
    if Ankole.Kernel.validate_web_url(endpoint, ["https"], true) == :ok,
      do: :ok,
      else: {:error, :invalid_endpoint}
  end

  defp validate_endpoint(_endpoint), do: {:error, :invalid_endpoint}

  defp decode(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> Base.url_decode64(value)
    end
  end

  defp decode(_value), do: :error

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp b64(data), do: Base.url_encode64(data, padding: false)

  defp truncate(nil, _limit), do: nil

  defp truncate(text, limit) when is_binary(text) do
    if String.length(text) > limit, do: String.slice(text, 0, limit - 1) <> "…", else: text
  end
end
