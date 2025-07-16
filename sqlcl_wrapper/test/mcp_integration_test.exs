defmodule SqlclWrapper.MCPIntegrationTest do
  use ExUnit.Case, async: true
  doctest SqlclWrapper.MCPServer

  alias SqlclWrapper.MCPServer
  alias HTTPoison

  setup do
    # Start the application
    {:ok, _apps} = Application.ensure_all_started(:sqlcl_wrapper)
    Process.sleep(500) # Give the server a moment to start up

    # Ensure the application is stopped after the test
    on_exit(fn ->
      Application.stop(:sqlcl_wrapper)
    end)

    :ok
  end

  test "GET /tools returns the list of available tools" do
    {:ok, %HTTPoison.Response{status_code: 200, body: body}} = HTTPoison.get("http://localhost:4000/mcp/tools")
    tools = Jason.decode!(body)

    assert is_list(tools)
    assert Enum.any?(tools, fn tool -> tool["name"] == "list-connections" end)
    assert Enum.any?(tools, fn tool -> tool["name"] == "connect" end)
    assert Enum.any?(tools, fn tool -> tool["name"] == "disconnect" end)
    assert Enum.any?(tools, fn tool -> tool["name"] == "run-sqlcl" end)
    assert Enum.any?(tools, fn tool -> tool["name"] == "run-sql" end)

    list_connections_tool = Enum.find(tools, fn tool -> tool["name"] == "list-connections" end)
    assert list_connections_tool["description"] == "List all available oracle named/saved connections in the connections storage"
    assert Map.has_key?(list_connections_tool["input_schema"], "filter")
  end

  test "calling a tool like list-connections returns a response" do
    # The MCPServer's handle_tool_call for list-connections returns a dummy response
    json_rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => "test-list-connections-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "name" => "list-connections",
        "arguments" => %{}
      }
    }

    {:ok, %HTTPoison.Response{status_code: 200, body: body}} =
      HTTPoison.post("http://localhost:4000/mcp/tool", Jason.encode!(json_rpc_request), [{"Content-Type", "application/json"}])

    response = Jason.decode!(body)
    assert response["jsonrpc"] == "2.0"
    assert response["result"] == %{"content" => [%{"type" => "text", "text" => "Connections: conn1, conn2"}]}
  end

  test "calling a tool like run-sqlcl returns a response" do
    expected_sqlcl_command = "show version"
    json_rpc_request = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => "test-run-sqlcl-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "name" => "run-sqlcl",
        "arguments" => %{"sqlcl" => expected_sqlcl_command}
      }
    }

    {:ok, %HTTPoison.Response{status_code: 200, body: body}} =
      HTTPoison.post("http://localhost:4000/mcp/tool", Jason.encode!(json_rpc_request), [{"Content-Type", "application/json"}])

    response = Jason.decode!(body)
    assert response["jsonrpc"] == "2.0"
    assert response["result"] == %{"content" => [%{"type" => "text", "text" => "Executed SQLcl command: #{expected_sqlcl_command}"}]}
  end
end
