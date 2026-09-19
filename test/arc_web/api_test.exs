defmodule ArcWeb.ApiTest do
  use Arc.RealtimeCase

  alias Arc.Apps

  @base "http://localhost:4002"

  setup do
    {app, config} = app_config_fixture()
    %{app: app, config: config}
  end

  defp post!(config, path, body, opts \\ []) do
    body = if is_binary(body), do: body, else: Jason.encode!(body)
    url = @base <> signed_path(config, "POST", path, body, Keyword.get(opts, :params, %{}))

    Req.post!(url,
      body: body,
      headers: [{"content-type", "application/json"}],
      retry: false,
      decode_body: false
    )
  end

  defp get!(config, path, params \\ %{}) do
    Req.get!(@base <> signed_path(config, "GET", path, "", params),
      retry: false,
      decode_body: false
    )
  end

  defp json(%{body: body}), do: Jason.decode!(body)

  describe "POST /events" do
    test "publishes to subscribers and returns {}", %{config: config} do
      {client, _} = connect!(config)
      subscribe!(client, "orders")
      next_frame!(client)

      resp =
        post!(config, "/apps/#{config.id}/events", %{
          name: "created",
          channel: "orders",
          data: ~s({"id":1})
        })

      assert resp.status == 200
      assert json(resp) == %{}
      assert %{"event" => "created", "data" => ~s({"id":1})} = next_frame!(client)
    end

    test "publishes to several channels", %{config: config} do
      {client, _} = connect!(config)
      for c <- ["a", "b"], do: subscribe!(client, c)
      next_frame!(client)
      next_frame!(client)

      resp =
        post!(config, "/apps/#{config.id}/events", %{name: "e", channels: ["a", "b"], data: "x"})

      assert resp.status == 200

      assert Enum.sort([next_frame!(client)["channel"], next_frame!(client)["channel"]]) == [
               "a",
               "b"
             ]
    end

    test "a publish with no subscribers is not an error", %{config: config} do
      resp = post!(config, "/apps/#{config.id}/events", %{name: "e", channel: "empty", data: "x"})
      assert resp.status == 200
      assert json(resp) == %{}
    end

    test "socket_id excludes the originator", %{config: config} do
      {a, a_id} = connect!(config)
      {b, _} = connect!(config)

      for c <- [a, b] do
        subscribe!(c, "room")
        next_frame!(c)
      end

      post!(config, "/apps/#{config.id}/events", %{
        name: "e",
        channel: "room",
        data: "x",
        socket_id: a_id
      })

      assert %{"event" => "e"} = next_frame!(b)
      refute_frame(a)
    end

    test "object data is encoded once", %{config: config} do
      {client, _} = connect!(config)
      subscribe!(client, "obj")
      next_frame!(client)
      post!(config, "/apps/#{config.id}/events", %{name: "e", channel: "obj", data: %{"a" => 1}})
      assert %{"data" => ~s({"a":1})} = next_frame!(client)
    end

    test "info returns user_count and subscription_count only when asked and allowed", %{app: app} do
      {:ok, _} = Apps.update_app(app, %{"subscription_count_enabled" => true})
      config = Apps.get_config(app.id)
      {client, socket_id} = connect!(config)
      subscribe_auth!(client, config, socket_id, "presence-r", ~s({"user_id":"u"}))
      await_event!(client, "pusher_internal:subscription_succeeded")

      eventually(fn ->
        Arc.Realtime.Occupancy.subscription_count(config.id, "presence-r") == 1
      end)

      resp =
        post!(config, "/apps/#{config.id}/events", %{
          name: "e",
          channels: ["presence-r", "public"],
          data: "x",
          info: "user_count,subscription_count"
        })

      assert json(resp) == %{
               "channels" => %{
                 "presence-r" => %{"user_count" => 1, "subscription_count" => 1},
                 "public" => %{"subscription_count" => 0}
               }
             }
    end

    test "validation errors are plain-text 400s", %{config: config} do
      cases = [
        %{channel: "a", data: "x"},
        %{name: "e", data: "x"},
        %{name: "e", channel: "bad name", data: "x"},
        %{name: "e", channel: "a"},
        %{name: "e", channels: [], data: "x"},
        %{name: "e", channels: Enum.map(1..101, &"c#{&1}"), data: "x"},
        %{name: "e", channel: "a", data: "x", socket_id: "nope"},
        %{name: "pusher:connection_established", channel: "a", data: "x"},
        %{name: String.duplicate("n", 201), channel: "a", data: "x"},
        %{name: "e", channel: "a", data: "x", info: 5}
      ]

      for body <- cases do
        resp = post!(config, "/apps/#{config.id}/events", body)
        assert resp.status == 400, "expected 400 for #{inspect(body)}, got #{resp.status}"
        assert hd(Req.Response.get_header(resp, "content-type")) =~ "text/plain"
        assert resp.body =~ ~r/\w/
      end
    end

    test "malformed JSON is a 400", %{config: config} do
      assert post!(config, "/apps/#{config.id}/events", "{nope").status == 400
      assert post!(config, "/apps/#{config.id}/events", "[1]").status == 400
    end

    test "payloads over the app limit are 413, and the limit can be raised", %{
      app: app,
      config: config
    } do
      big = String.duplicate("x", 10_241)
      resp = post!(config, "/apps/#{config.id}/events", %{name: "e", channel: "a", data: big})
      assert resp.status == 413
      assert resp.body =~ "10240"

      {:ok, _} = Apps.update_app(app, %{"max_payload_bytes" => 20_000})

      assert post!(Apps.get_config(app.id), "/apps/#{config.id}/events", %{
               name: "e",
               channel: "a",
               data: big
             }).status == 200
    end
  end

  describe "POST /batch_events" do
    test "publishes up to 10 events", %{config: config} do
      {client, _} = connect!(config)
      subscribe!(client, "b")
      next_frame!(client)

      batch = for i <- 1..3, do: %{name: "e#{i}", channel: "b", data: "#{i}"}
      resp = post!(config, "/apps/#{config.id}/batch_events", %{batch: batch})
      assert resp.status == 200
      assert json(resp) == %{}
      assert ["e1", "e2", "e3"] == for(_ <- 1..3, do: next_frame!(client)["event"])
    end

    test "rejects more than 10, empty, and invalid entries", %{config: config} do
      batch = for i <- 1..11, do: %{name: "e", channel: "c#{i}", data: "x"}
      assert post!(config, "/apps/#{config.id}/batch_events", %{batch: batch}).status == 400
      assert post!(config, "/apps/#{config.id}/batch_events", %{batch: []}).status == 400
      assert post!(config, "/apps/#{config.id}/batch_events", %{}).status == 400

      resp =
        post!(config, "/apps/#{config.id}/batch_events", %{
          batch: [%{name: "e", channel: "a", data: "x"}, 5]
        })

      assert resp.status == 400
      assert resp.body =~ "batch[1]"
      resp = post!(config, "/apps/#{config.id}/batch_events", %{batch: [%{name: "e", data: "x"}]})
      assert resp.body =~ "batch[0]"
    end

    test "returns per-event info when requested", %{config: config} do
      {client, socket_id} = connect!(config)
      subscribe_auth!(client, config, socket_id, "presence-b", ~s({"user_id":"u"}))
      await_event!(client, "pusher_internal:subscription_succeeded")

      resp =
        post!(config, "/apps/#{config.id}/batch_events", %{
          batch: [
            %{name: "e", channel: "presence-b", data: "x", info: "user_count"},
            %{name: "e", channel: "other", data: "x"}
          ]
        })

      assert json(resp) == %{"batch" => [%{"user_count" => 1}, %{}]}
    end
  end

  describe "channel queries" do
    setup %{config: config} do
      {client, socket_id} = connect!(config)
      subscribe!(client, "public-1")
      subscribe_auth!(client, config, socket_id, "presence-room-1", ~s({"user_id":"u1"}))
      await_event!(client, "pusher_internal:subscription_succeeded")
      await_event!(client, "pusher_internal:subscription_succeeded")
      eventually(fn -> map_size(Arc.Realtime.occupied_channels(config.id)) == 2 end)
      %{client: client}
    end

    test "GET /channels lists occupied channels as an object keyed by name", %{config: config} do
      resp = get!(config, "/apps/#{config.id}/channels")
      assert json(resp) == %{"channels" => %{"public-1" => %{}, "presence-room-1" => %{}}}

      resp =
        get!(config, "/apps/#{config.id}/channels", %{
          "filter_by_prefix" => "presence-",
          "info" => "user_count"
        })

      assert json(resp) == %{"channels" => %{"presence-room-1" => %{"user_count" => 1}}}
    end

    test "user_count without a presence prefix is a 400", %{config: config} do
      assert get!(config, "/apps/#{config.id}/channels", %{"info" => "user_count"}).status == 400
      assert get!(config, "/apps/#{config.id}/channels", %{"info" => "bogus"}).status == 400
    end

    test "subscription_count must be enabled", %{app: app, config: config} do
      assert get!(config, "/apps/#{config.id}/channels", %{"info" => "subscription_count"}).status ==
               403

      {:ok, _} = Apps.update_app(app, %{"subscription_count_enabled" => true})
      config = Apps.get_config(app.id)
      resp = get!(config, "/apps/#{config.id}/channels", %{"info" => "subscription_count"})
      assert json(resp)["channels"]["public-1"] == %{"subscription_count" => 1}
    end

    test "GET /channels/:name", %{config: config} do
      assert json(get!(config, "/apps/#{config.id}/channels/public-1")) == %{"occupied" => true}
      assert json(get!(config, "/apps/#{config.id}/channels/nobody")) == %{"occupied" => false}

      resp =
        get!(config, "/apps/#{config.id}/channels/presence-room-1", %{"info" => "user_count"})

      assert json(resp) == %{"occupied" => true, "user_count" => 1}

      assert get!(config, "/apps/#{config.id}/channels/public-1", %{"info" => "user_count"}).status ==
               400
    end

    test "GET /channels/:name/users", %{config: config} do
      assert json(get!(config, "/apps/#{config.id}/channels/presence-room-1/users")) == %{
               "users" => [%{"id" => "u1"}]
             }

      assert get!(config, "/apps/#{config.id}/channels/public-1/users").status == 400
    end
  end

  describe "POST /users/:id/terminate_connections" do
    test "closes the user's connections", %{config: config} do
      {client, socket_id} = connect!(config)
      user_data = ~s({"id":"bad-actor"})
      auth = Arc.Channels.Auth.sign_user(config, socket_id, user_data)

      WsClient.send_json(client, %{
        event: "pusher:signin",
        data: %{auth: auth, user_data: user_data}
      })

      await_event!(client, "pusher:signin_success")

      resp = post!(config, "/apps/#{config.id}/users/bad-actor/terminate_connections", "")
      assert resp.status == 200
      assert json(resp) == %{}
      assert {4300, _} = await_close!(client)
    end

    test "is also accepted without an app id in the path", %{config: config} do
      {client, socket_id} = connect!(config)
      user_data = ~s({"id":"no-app-path"})
      auth = Arc.Channels.Auth.sign_user(config, socket_id, user_data)

      WsClient.send_json(client, %{
        event: "pusher:signin",
        data: %{auth: auth, user_data: user_data}
      })

      await_event!(client, "pusher:signin_success")

      resp = post!(config, "/users/no-app-path/terminate_connections", "{}")
      assert resp.status == 200
      assert {4300, _} = await_close!(client)

      resp = post!(%{config | key: "unknown"}, "/users/x/terminate_connections", "{}")
      assert resp.status == 401
    end
  end

  describe "request signing" do
    test "an invalid signature is a 401", %{config: config} do
      body = Jason.encode!(%{name: "e", channel: "a", data: "x"})
      path = signed_path(config, "POST", "/apps/#{config.id}/events", body)

      tampered =
        String.replace(
          path,
          ~r/auth_signature=[0-9a-f]+/,
          "auth_signature=" <> String.duplicate("0", 64)
        )

      resp = Req.post!(@base <> tampered, body: body, retry: false)
      assert resp.status == 401
      assert resp.body =~ "Invalid signature"
    end

    test "a signature by another app's secret is a 401", %{config: config} do
      {_other, other} = app_config_fixture()
      forged = %{other | key: config.key}

      assert post!(forged, "/apps/#{config.id}/events", %{name: "e", channel: "a", data: "x"}).status ==
               401
    end

    test "a rotated secret stops verifying immediately", %{app: app, config: config} do
      {:ok, _, _} = Apps.rotate_secret(app)

      assert post!(config, "/apps/#{config.id}/events", %{name: "e", channel: "a", data: "x"}).status ==
               401

      assert post!(Apps.get_config(app.id), "/apps/#{config.id}/events", %{
               name: "e",
               channel: "a",
               data: "x"
             }).status == 200
    end

    test "a stale timestamp is a 401", %{config: config} do
      body = Jason.encode!(%{name: "e", channel: "a", data: "x"})
      old = Integer.to_string(System.system_time(:second) - 601)

      params = %{
        "auth_key" => config.key,
        "auth_timestamp" => old,
        "auth_version" => "1.0",
        "body_md5" => md5(body)
      }

      resp =
        Req.post!(@base <> sign_raw(config, "POST", "/apps/#{config.id}/events", params),
          body: body,
          retry: false
        )

      assert resp.status == 401
      assert resp.body =~ "Timestamp"
    end

    test "a body that does not match body_md5 is a 401", %{config: config} do
      body = Jason.encode!(%{name: "e", channel: "a", data: "x"})
      path = signed_path(config, "POST", "/apps/#{config.id}/events", body)
      resp = Req.post!(@base <> path, body: body <> " ", retry: false)
      assert resp.status == 401
      assert resp.body =~ "body_md5"
    end

    test "missing parameters, wrong key, and wrong version are 401s", %{config: config} do
      assert Req.get!(@base <> "/apps/#{config.id}/channels", retry: false).status == 401

      params = %{"auth_key" => "wrong", "auth_timestamp" => now(), "auth_version" => "1.0"}

      assert Req.get!(@base <> sign_raw(config, "GET", "/apps/#{config.id}/channels", params),
               retry: false
             ).status == 401

      params = %{"auth_key" => config.key, "auth_timestamp" => now(), "auth_version" => "2.0"}

      assert Req.get!(@base <> sign_raw(config, "GET", "/apps/#{config.id}/channels", params),
               retry: false
             ).status == 401

      params = %{"auth_key" => config.key, "auth_timestamp" => "soon", "auth_version" => "1.0"}

      assert Req.get!(@base <> sign_raw(config, "GET", "/apps/#{config.id}/channels", params),
               retry: false
             ).status == 401

      body = "{}"
      params = %{"auth_key" => config.key, "auth_timestamp" => now(), "auth_version" => "1.0"}

      resp =
        Req.post!(@base <> sign_raw(config, "POST", "/apps/#{config.id}/events", params),
          body: body,
          retry: false
        )

      assert resp.status == 401
    end

    test "unknown apps are 404 and disabled apps 403", %{app: app, config: config} do
      assert get!(%{config | id: 999_999_999}, "/apps/999999999/channels").status == 404
      assert Req.get!(@base <> "/apps/abc/channels", retry: false).status == 404

      {:ok, _} = Apps.update_app(app, %{"enabled" => false})
      assert get!(config, "/apps/#{config.id}/channels").status == 403
    end

    test "requests over the per-app rate limit are 429", %{config: config} do
      original = Application.fetch_env!(:arc, Arc.Realtime)
      Application.put_env(:arc, Arc.Realtime, Keyword.merge(original, api_rate: 1, api_burst: 2))
      Arc.RateLimiter.reset({:api, config.id})

      on_exit(fn ->
        Application.put_env(:arc, Arc.Realtime, original)
        Arc.RateLimiter.reset({:api, config.id})
      end)

      statuses = for _ <- 1..4, do: get!(config, "/apps/#{config.id}/channels").status
      assert 429 in statuses
      assert Enum.take(statuses, 2) == [200, 200]
    end
  end

  defp now, do: Integer.to_string(System.system_time(:second))
  defp md5(body), do: :crypto.hash(:md5, body) |> Base.encode16(case: :lower)

  defp sign_raw(config, method, path, params) do
    query = params |> Enum.sort() |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)

    sig =
      :crypto.mac(:hmac, :sha256, config.secret, "#{method}\n#{path}\n#{query}")
      |> Base.encode16(case: :lower)

    path <> "?" <> URI.encode_query(Map.put(params, "auth_signature", sig))
  end
end
