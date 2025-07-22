defmodule SqlclWrapper.MCPClient do
  require Logger
  Logger.info("client init")
  use Hermes.Client,
    name: "MyApp",
    version: "1.0.0",
    protocol_version: "2025-03-26"
end
