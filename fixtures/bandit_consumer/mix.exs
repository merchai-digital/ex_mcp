defmodule ExMCPBanditConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :ex_mcp_bandit_consumer,
      version: "0.1.0",
      elixir: "~> 1.17",
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :ex_mcp]]
  end

  defp deps do
    [
      {:ex_mcp, path: "../.."},
      {:bandit, "~> 1.5"}
    ]
  end
end
