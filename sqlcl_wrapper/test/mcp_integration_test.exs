defmodule SqlclWrapper.MCPIntegrationTest do
  use ExUnit.Case, async: false
  doctest SqlclWrapper.MCPServer

  alias SqlclWrapper.MCPServer

  setup do
    # Start the application which will start all needed components
    {:ok, _apps} = Application.ensure_all_started(:sqlcl_wrapper)
    Process.sleep(1000) # Give the server a moment to start up

    # Get the MCP server from the registry
    mcp_server = Hermes.Server.Registry.whereis_server(SqlclWrapper.MCPServer)

    on_exit(fn ->
      Application.stop(:sqlcl_wrapper)
    end)

    %{mcp_server: mcp_server}
  end

  test "MCP server can handle tools/list requests", %{mcp_server: mcp_server} do
    # Step 1: Initialize the server
    init_message = %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "id" => "test-init-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{},
        "clientInfo" => %{
          "name" => "test-client",
          "version" => "1.0.0"
        }
      }
    }

    {:ok, init_response} = GenServer.call(mcp_server, {:request, init_message, "test-session", %{}})
    init_response_data = Jason.decode!(init_response)
    assert init_response_data["jsonrpc"] == "2.0"
    assert Map.has_key?(init_response_data, "result")

    # Step 2: Send initialized notification
    initialized_notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    # Send notification (no response expected)
    GenServer.cast(mcp_server, {:notification, initialized_notification, "test-session", %{}})

    # Step 3: Now request tools list
    message = %{
      "jsonrpc" => "2.0",
      "method" => "tools/list",
      "id" => "test-tools-list-#{System.unique_integer([:monotonic])}",
      "params" => %{}
    }

    {:ok, response} = GenServer.call(mcp_server, {:request, message, "test-session", %{}})

    # Parse response
    response_data = Jason.decode!(response)
    assert response_data["jsonrpc"] == "2.0"

    # Check if it's an error response
    if Map.has_key?(response_data, "error") do
      IO.inspect(response_data["error"], label: "ERROR")
      flunk("Server returned error: #{inspect(response_data["error"])}")
    end

    assert response_data["id"] == message["id"]

    tools = response_data["result"]["tools"]
    assert is_list(tools)
    assert Enum.any?(tools, fn tool -> tool["name"] == "list-connections" end)
    assert Enum.any?(tools, fn tool -> tool["name"] == "connect" end)
    assert Enum.any?(tools, fn tool -> tool["name"] == "disconnect" end)
    assert Enum.any?(tools, fn tool -> tool["name"] == "run-sqlcl" end)
    assert Enum.any?(tools, fn tool -> tool["name"] == "run-sql" end)
  end

  test "MCP server can handle tools/call requests", %{mcp_server: mcp_server} do
    message = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => "test-list-connections-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "name" => "list-connections",
        "arguments" => %{}
      }
    }

    {:ok, response} = GenServer.call(mcp_server, {:request, message, "test-session", %{}})

    # Parse response
    response_data = Jason.decode!(response)
    assert response_data["jsonrpc"] == "2.0"
    assert response_data["result"] == %{"content" => [%{"type" => "text", "text" => "Connections: conn1, conn2"}]}
  end

  test "MCP server can handle run-sqlcl tool calls", %{mcp_server: mcp_server} do
    expected_sqlcl_command = "show version"
    message = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => "test-run-sqlcl-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "name" => "run-sqlcl",
        "arguments" => %{"sqlcl" => expected_sqlcl_command}
      }
    }

    {:ok, response} = GenServer.call(mcp_server, {:request, message, "test-session", %{}})

    # Parse response
    response_data = Jason.decode!(response)
    assert response_data["jsonrpc"] == "2.0"
    assert response_data["result"] == %{"content" => [%{"type" => "text", "text" => "Executed SQLcl command: #{expected_sqlcl_command}"}]}
  end

  defp wait_for_server_ready(0), do: flunk("Server did not become ready in time")
  defp wait_for_server_ready(remaining_attempts) do
    case GenServer.call(SqlclWrapper.SqlclProcess, :is_server_ready, 1000) do
      true -> :ok
      false ->
        Process.sleep(100)
        wait_for_server_ready(remaining_attempts - 1)
    end
  rescue
    _ ->
      Process.sleep(100)
      wait_for_server_ready(remaining_attempts - 1)
  end
end
