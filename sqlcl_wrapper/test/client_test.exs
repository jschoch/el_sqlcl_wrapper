defmodule SqlclWrapper.MCPClientTest do
  use ExUnit.Case, async: false
  import SqlclWrapper.IntegrationTestHelper
  require Logger

  @moduledoc """
  Tests MCP protocol compliance, SQL execution, and connection management.
  """

  setup_all do

    :ok
  end

  test "do a thing" do
    #{first, result} = SqlclWrapper.MCPClient.call_tool("initialize", %{mcp_client: "blaz", model: "bluz"})
    #{first, result} = SqlclWrapper.MCPClient.call_tool("list", %{mcp_client: "blaz", model: "bluz"})
    SqlclWrapper.MCPClient.get_server_capabilities()
    {first, result} = SqlclWrapper.MCPClient.call_tool("list-connections", %{mcp_client: "blaz", model: "bluz"})
    #assert :ok == first, "result was #{inspect( result)}"
    assert false, "not done"
end
end
