defmodule ExMCPBanditConsumer.Handler do
  @moduledoc "A small MCP handler for the Bandit-only dependency proof."

  use ExMCP.Server.Handler
  use ExMCP.Server.DSL, name: "bandit-consumer", version: "1.0.0"

  tool "ping", "Returns a short response" do
    input_schema(%{type: "object", properties: %{}})

    run(fn _arguments, state ->
      {:ok, %{content: [%{"type" => "text", "text" => "pong"}]}, state}
    end)
  end
end
