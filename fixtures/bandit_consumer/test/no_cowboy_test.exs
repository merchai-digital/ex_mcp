defmodule ExMCPBanditConsumer.NoCowboyTest do
  use ExUnit.Case, async: false

  alias ExMCP.Server.Transport

  test "Bandit serves initialize, request, and finite stream without Cowboy" do
    selected = Mix.Dep.Lock.read()

    refute Enum.any?(
             [:plug_cowboy, :cowboy, :cowboy_telemetry, :cowlib, :ranch],
             &Map.has_key?(selected, &1)
           )

    selected_paths = Mix.Project.deps_paths()

    refute Enum.any?(
             [:plug_cowboy, :cowboy, :cowboy_telemetry, :cowlib, :ranch],
             &Map.has_key?(selected_paths, &1)
           )

    refute Code.ensure_loaded?(Plug.Cowboy)
    refute Transport.list_transports().http.available

    assert {:error, :cowboy_not_available} =
             Transport.start_http_server(ExMCPBanditConsumer.Handler, %{}, [], port: 0)

    assert {:error, :cowboy_not_available} =
             Transport.start_http_server(ExMCPBanditConsumer.Handler, %{}, [],
               port: 0,
               ranch_ref: :unused
             )

    server =
      start_supervised!(
        {Bandit,
         plug:
           {ExMCP.HttpPlug,
            handler: ExMCPBanditConsumer.Handler,
            server_info: %{name: "bandit-consumer", version: "1.0.0"},
            protocol_mode: :prefer_modern,
            subscription_keepalive_interval_ms: 5,
            subscription_max_lifetime_ms: 25},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}/"

    initialize = %{
      "jsonrpc" => "2.0",
      "id" => 1,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{"name" => "consumer", "version" => "1.0.0"}
      }
    }

    {200, initialize_headers, initialized} = request(url, initialize)
    assert initialized["result"]
    session_id = header(initialize_headers, "mcp-session-id")
    assert is_binary(session_id)

    {200, _headers, tools} =
      request(url, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"}, [
        {"mcp-session-id", session_id},
        {"mcp-protocol-version", "2025-06-18"}
      ])

    assert [%{"name" => "ping"}] = tools["result"]["tools"]

    meta = %{
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    listen = %{
      "jsonrpc" => "2.0",
      "id" => 3,
      "method" => "subscriptions/listen",
      "params" => %{
        "notifications" => %{"toolsListChanged" => true},
        "_meta" => meta
      }
    }

    {200, stream_headers, body} =
      raw_request(url, listen, [
        {"mcp-protocol-version", "2026-07-28"},
        {"mcp-method", "subscriptions/listen"}
      ])

    assert header(stream_headers, "content-type") =~ "text/event-stream"
    assert body =~ "notifications/subscriptions/acknowledged"
    assert body =~ "\"resultType\":\"complete\""
  end

  defp request(url, payload, headers \\ []) do
    {status, response_headers, body} = raw_request(url, payload, headers)
    {status, response_headers, Jason.decode!(body)}
  end

  defp raw_request(url, payload, headers) do
    headers = [{"accept", "application/json, text/event-stream"} | headers]

    headers =
      Enum.map(headers, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

    body = Jason.encode!(payload)

    {:ok, {{_version, status, _reason}, response_headers, response_body}} =
      :httpc.request(
        :post,
        {String.to_charlist(url), headers, ~c"application/json", body},
        [timeout: 5_000],
        []
      )

    {status, response_headers, to_string(response_body)}
  end

  defp header(headers, name) do
    case List.keyfind(headers, String.to_charlist(name), 0) do
      {_, value} -> to_string(value)
      nil -> nil
    end
  end
end
