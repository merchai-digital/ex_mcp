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

  test "oversized POST leaves the same Bandit socket usable for a following request" do
    server =
      start_supervised!(
        {Bandit,
         plug:
           {ExMCP.HttpPlug,
            handler: ExMCPBanditConsumer.Handler,
            server_info: %{name: "bandit-consumer", version: "1.0.0"}},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 5_000)
    on_exit(fn -> :gen_tcp.close(socket) end)

    send_post(socket, String.duplicate("x", 1_000_001), "tools/list")
    assert {413, "Request body too large"} = receive_response(socket)

    request = %{
      "jsonrpc" => "2.0",
      "id" => 2,
      "method" => "tools/list",
      "params" => %{
        "_meta" => %{
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => %{}
        }
      }
    }

    send_post(socket, Jason.encode!(request), "tools/list")
    assert {200, body} = receive_response(socket)
    assert %{"result" => %{"tools" => [%{"name" => "ping"}]}} = Jason.decode!(body)
  end

  defp send_post(socket, body, method) do
    :ok =
      :gen_tcp.send(socket, [
        "POST / HTTP/1.1\r\n",
        "Host: 127.0.0.1\r\n",
        "Connection: keep-alive\r\n",
        "Content-Type: application/json\r\n",
        "MCP-Protocol-Version: 2026-07-28\r\n",
        "MCP-Method: ",
        method,
        "\r\n",
        "Content-Length: ",
        Integer.to_string(byte_size(body)),
        "\r\n\r\n",
        body
      ])
  end

  defp receive_response(socket) do
    {head, body_start} = receive_headers(socket, "")
    [status_line | headers] = String.split(head, "\r\n")
    ["HTTP/1.1", status | _] = String.split(status_line, " ")

    length =
      headers
      |> Enum.find_value(fn header ->
        case String.split(header, ":", parts: 2) do
          [name, value] ->
            if String.downcase(name) == "content-length",
              do: String.to_integer(String.trim(value))

          _ ->
            nil
        end
      end)

    remaining = length - byte_size(body_start)

    tail =
      if remaining > 0 do
        {:ok, chunk} = :gen_tcp.recv(socket, remaining, 5_000)
        chunk
      else
        ""
      end

    {String.to_integer(status), body_start <> tail}
  end

  defp receive_headers(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, body] ->
        {head, body}

      [_incomplete] ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)
        receive_headers(socket, buffer <> chunk)
    end
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
