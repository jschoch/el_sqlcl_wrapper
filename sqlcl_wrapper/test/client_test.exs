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
    {first, result} = SqlclWrapper.MCPClient.call_tool("echo", %{text: "this will be echoed!"})
    assert :ok = first
    assert false, "not done"
end
end
