defmodule SqlclWrapper.IntegrationTestHelper do
  require Logger

  @doc """
  Provides common setup and helper functions for SQLcl integration tests.
  """
  def do_setup_all(%{port: port}) do
    Logger.info("Test setup for port #{port}")
    # The application supervisor will start SqlclWrapper.MCPServer and SqlclWrapper.SqlclProcess
    # No need to manually start Plug.Cowboy or perform MCP handshake here,
    # as Hermes.Server handles the HTTP transport and MCP protocol.
    :ok
  end
end
