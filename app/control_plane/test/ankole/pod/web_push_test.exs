defmodule Ankole.Pod.WebPushTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures

  import Ecto.Query, only: [from: 2]

  alias Ankole.{Conversations, Repo}
  alias Ankole.Pod.{WebPush, WebPushSubscription}

  @endpoint "https://push.example.com/send/browser-1"

  setup do
    alice = human_fixture(%{display_name: "Alice"}).principal
    bob = human_fixture(%{display_name: "Bob"}).principal
    agent = agent_fixture(%{owner_principal_uid: alice.uid, display_name: "Researcher"}).principal
    Ankole.ConversationsFixtures.grant_chat(alice.uid, agent.uid)
    {public, private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)

    %{
      alice: alice,
      bob: bob,
      agent: agent,
      browser: %{public: public, private: private, auth: auth},
      subscription: %{
        endpoint: @endpoint,
        p256dh: Base.url_encode64(public, padding: false),
        auth: Base.url_encode64(auth, padding: false),
        userAgent: "Test browser"
      }
    }
  end

  test "encrypts a payload exactly as the RFC 8291 example does" do
    d = &Base.url_decode64!(&1, padding: false)

    body =
      WebPush.encrypt(
        "When I grow up, I want to be a watermelon",
        d.(
          "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
        ),
        d.("BTBZMqHH6r4Tts7J_aSIgg"),
        {d.(
           "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
         ), d.("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")},
        d.("DGv6ra1nlYgDCS1FRnbzlw")
      )

    assert Base.url_encode64(body, padding: false) ==
             "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27ml" <>
               "mlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPT" <>
               "pK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"
  end

  test "signs a VAPID token that the push service can verify" do
    {public, _} = keys = :crypto.generate_key(:ecdh, :prime256v1)

    "vapid t=" <> rest =
      WebPush.vapid_authorization("https://push.example.com:443/send/abc", keys, 1_000)

    [token, "k=" <> key] = String.split(rest, ", ")
    [header, claims, signature] = String.split(token, ".")
    claims = claims |> Base.url_decode64!(padding: false) |> JSON.decode!()

    assert claims["aud"] == "https://push.example.com"
    assert claims["exp"] == 1_000 + 12 * 3600
    assert String.starts_with?(claims["sub"], "https://")
    assert Base.url_decode64!(key, padding: false) == public

    <<r::256, s::256>> = Base.url_decode64!(signature, padding: false)
    der = :public_key.der_encode(:"ECDSA-Sig-Value", {:"ECDSA-Sig-Value", r, s})

    assert :crypto.verify(:ecdsa, :sha256, header <> "." <> claims_segment(token), der, [
             public,
             :prime256v1
           ])
  end

  test "the VAPID public key stays the same for one installation" do
    key = WebPush.public_key()
    assert key == WebPush.public_key()
    assert <<4, _::binary-size(64)>> = Base.url_decode64!(key, padding: false)
  end

  test "a browser subscription belongs to the Human who signed in to it last", ctx do
    alice = actor_fixture(ctx.alice.uid)
    bob = actor_fixture(ctx.bob.uid)

    assert {:ok, %{subscribed: true}} = WebPush.subscribe(alice, ctx.subscription)
    assert {:ok, %{subscribed: true}} = WebPush.subscribe(bob, ctx.subscription)
    assert [%{principal_uid: uid, user_agent: "Test browser"}] = subscriptions()
    assert uid == ctx.bob.uid

    assert {:ok, %{subscribed: false}} = WebPush.unsubscribe(alice, @endpoint)
    assert [_] = subscriptions()
    assert {:ok, %{subscribed: false}} = WebPush.unsubscribe(bob, @endpoint)
    assert [] = subscriptions()
  end

  test "a subscription needs a public https push service and complete keys", ctx do
    alice = actor_fixture(ctx.alice.uid)

    assert {:error, :invalid_endpoint} =
             WebPush.subscribe(alice, %{ctx.subscription | endpoint: "http://push.example.com/x"})

    assert {:error, :invalid_endpoint} =
             WebPush.subscribe(alice, %{ctx.subscription | endpoint: "https://127.0.0.1/x"})

    assert {:error, :invalid_subscription} =
             WebPush.subscribe(alice, %{ctx.subscription | auth: "c2hvcnQ"})

    assert {:error, :invalid_subscription} =
             WebPush.subscribe(alice, %{ctx.subscription | p256dh: "not a key"})

    off_curve = Base.url_encode64(<<4>> <> :binary.copy(<<1>>, 64), padding: false)

    assert {:error, :invalid_subscription} =
             WebPush.subscribe(alice, %{ctx.subscription | p256dh: off_curve})

    assert [] = subscriptions()
  end

  test "pushes a room's newest message once to each other Human who has not read it", ctx do
    id = room!(ctx)
    {:ok, _} = WebPush.subscribe(actor_fixture(ctx.bob.uid), ctx.subscription)
    stub_push(201)

    assert :ok = WebPush.deliver(id, push())
    assert_received {:push, headers, body}

    # Req's test plug consumes the content-encoding header, so the decrypted body checks the encoding.
    assert ["high"] = headers["urgency"]
    assert ["vapid t=" <> _] = headers["authorization"]

    payload = decrypt(body, ctx.browser)
    assert payload["title"] == Conversations.get_conversation!(id).title
    # Adding Bob is the newest notifiable message, as his unread dot shows.
    assert payload["body"] =~ ~r/^Alice: /
    assert payload["url"] == AnkoleWeb.PodURL.conversation_path(id)
    assert payload["tag"] == id
    assert payload["decision"] == false

    assert :ok = WebPush.deliver(id, push())
    refute_received {:push, _, _}

    post!(ctx.alice, id, "Second")
    assert :ok = WebPush.deliver(id, push())
    assert_received {:push, _, body}
    assert decrypt(body, ctx.browser)["body"] == "Alice: Second"
  end

  test "a Human who read the message or muted the room gets no push", ctx do
    id = room!(ctx)
    bob = actor_fixture(ctx.bob.uid)
    {:ok, _} = WebPush.subscribe(bob, ctx.subscription)
    stub_push(201)

    high_water = Conversations.get_conversation!(id).sequence_high_water
    {:ok, _} = Conversations.update_conversation(bob, id, %{last_read_seq: high_water})
    assert :ok = WebPush.deliver(id, push())
    refute_received {:push, _, _}

    {:ok, _} = Conversations.update_conversation(bob, id, %{muted: true})
    post!(ctx.alice, id, "Ordinary news")
    assert :ok = WebPush.deliver(id, push())
    refute_received {:push, _, _}

    # Unmuting later does not bring back the message that the muted room skipped.
    {:ok, _} = Conversations.update_conversation(bob, id, %{muted: false})
    assert :ok = WebPush.deliver(id, push())
    refute_received {:push, _, _}

    # A decision reaches the Human even in a muted room.
    {:ok, _} = Conversations.update_conversation(bob, id, %{muted: true})
    message_id = post!(ctx.alice, id, "Which one?")

    Repo.query!(
      "UPDATE conversation_messages SET rich_content = $1 WHERE tenant_id = $2 AND id = $3",
      [
        %{"connector_auth" => %{"provider" => "github"}},
        Ecto.UUID.dump!(Repo.tenant_id!()),
        Ecto.UUID.dump!(message_id)
      ]
    )

    assert :ok = WebPush.deliver(id, push())
    assert_received {:push, _, body}
    assert decrypt(body, ctx.browser)["decision"] == true
  end

  test "a delivery waits until the newest message has settled", ctx do
    id = room!(ctx)
    {:ok, _} = WebPush.subscribe(actor_fixture(ctx.bob.uid), ctx.subscription)
    stub_push(201)

    assert {:snooze, seconds} =
             WebPush.deliver(id, push() ++ [settled_before: DateTime.add(DateTime.utc_now(), -5)])

    assert seconds in 1..5
    refute_received {:push, _, _}

    assert :ok = WebPush.deliver(id, push() ++ [settled_before: DateTime.utc_now()])
    assert_received {:push, _, _}
  end

  test "an unusable subscription does not stop the others", ctx do
    id = room!(ctx)
    bob = actor_fixture(ctx.bob.uid)
    {:ok, _} = WebPush.subscribe(bob, ctx.subscription)
    {:ok, _} = WebPush.subscribe(bob, %{ctx.subscription | endpoint: @endpoint <> "-2"})

    # A row whose key is not a curve point, as an older or corrupted subscription could be.
    Repo.query!(
      "UPDATE web_push_subscriptions SET p256dh = $1 WHERE tenant_id = $2 AND endpoint = $3",
      [
        Base.url_encode64(<<4>> <> :binary.copy(<<1>>, 64), padding: false),
        Ecto.UUID.dump!(Repo.tenant_id!()),
        @endpoint
      ]
    )

    stub_push(201)
    assert :ok = WebPush.deliver(id, push())
    assert_received {:push, _, _}
  end

  test "Ankole forgets a subscription that the push service reports gone", ctx do
    id = room!(ctx)
    {:ok, _} = WebPush.subscribe(actor_fixture(ctx.bob.uid), ctx.subscription)
    stub_push(410)

    assert :ok = WebPush.deliver(id, push())
    assert_received {:push, _, _}
    assert [] = subscriptions()
  end

  test "a committed room message schedules one delivery for the room", ctx do
    id = room!(ctx)
    post!(ctx.alice, id, "Another")

    jobs =
      Repo.all(
        from(job in Oban.Job,
          where: job.worker == "Ankole.Pod.Jobs.DeliverWebPush" and job.state == "scheduled"
        )
      )

    assert [%{args: %{"conversation_id" => ^id}}] =
             Enum.filter(jobs, &(&1.args["conversation_id"] == id))
  end

  defp room!(ctx) do
    {:ok, detail} =
      Ankole.ConversationsFixtures.create(ctx.alice.uid, %{
        conversation_id: Ash.UUIDv7.generate(),
        message_id: Ash.UUIDv7.generate(),
        agent_uid: ctx.agent.uid,
        room_mode: :group,
        text: "Start"
      })

    id = detail.conversation.id

    {:ok, _} =
      Conversations.manage_participants(actor_fixture(ctx.alice.uid), id, %{
        add_uids: [ctx.bob.uid]
      })

    id
  end

  defp post!(human, id, text) do
    message_id = Ash.UUIDv7.generate()

    {:ok, result} =
      Repo.transact(fn ->
        Conversations.post_in_tx(actor_fixture(human.uid), id, %{
          message_id: message_id,
          text: text
        })
      end)

    :ok = Conversations.publish_native_change(result)
    message_id
  end

  defp stub_push(status) do
    test = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      headers = Enum.group_by(conn.req_headers, &elem(&1, 0), &elem(&1, 1))
      send(test, {:push, headers, body})
      Plug.Conn.send_resp(conn, status, "")
    end)
  end

  defp push, do: [req_options: [plug: {Req.Test, __MODULE__}]]

  defp subscriptions, do: Ankole.Ash.read!(WebPushSubscription)

  defp claims_segment(token), do: token |> String.split(".") |> Enum.at(1)

  # The browser's side of RFC 8291.
  defp decrypt(body, browser) do
    <<salt::binary-size(16), _size::32, 65, sender::binary-size(65), rest::binary>> = body
    secret = :crypto.compute_key(:ecdh, sender, browser.private, :prime256v1)
    info = "WebPush: info" <> <<0>> <> browser.public <> sender <> <<1>>
    prk = hmac(salt, hmac(hmac(browser.auth, secret), info))
    <<key::binary-size(16), _::binary>> = hmac(prk, "Content-Encoding: aes128gcm" <> <<0, 1>>)
    <<nonce::binary-size(12), _::binary>> = hmac(prk, "Content-Encoding: nonce" <> <<0, 1>>)
    size = byte_size(rest) - 16
    <<ciphertext::binary-size(^size), tag::binary-size(16)>> = rest
    plain = :crypto.crypto_one_time_aead(:aes_128_gcm, key, nonce, ciphertext, <<>>, tag, false)
    plain |> binary_part(0, byte_size(plain) - 1) |> JSON.decode!()
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
end
