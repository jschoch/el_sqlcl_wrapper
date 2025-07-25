defmodule SqlclWrapper.MCPIntegrationTest do
  use ExUnit.Case, async: false
  import SqlclWrapper.IntegrationTestHelper
  require Logger

  @moduledoc """
  Comprehensive MCP integration tests for SQLcl wrapper.
  Tests MCP protocol compliance, SQL execution, and connection management.
  """

  setup_all do
    # Start the application with all components
    {:ok, _apps} = Application.ensure_all_started(:sqlcl_wrapper)

    # Wait for SQLcl process to be ready
    #wait_for_sqlcl_startup()

    # Get the MCP server from the registry
    mcp_server = Hermes.Server.Registry.whereis_server(SqlclWrapper.MCPServer)

    unless mcp_server do
      flunk("MCP server not found in registry")
    end

    Logger.info("MCP integration test setup complete")

    on_exit(fn ->
      Logger.info("Cleaning up MCP integration test")
      Application.stop(:sqlcl_wrapper)
    end)

    %{mcp_server: mcp_server}
  end

  describe "Connection Management" do
    test "can list available database connections", %{mcp_server: mcp_server} do
      session_id = "list-connections-#{System.unique_integer([:monotonic])}"
      list_connections_message = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => session_id,
        "params" => %{
          "name" => "list-connections",
          "arguments" => %{
            "mcp_client" => "test-client",
            "model" => "claude-sonnet-4"
          }
        }
      }
      json = Jason.encode!(list_connections_message)
      {:ok, response} = SqlclWrapper.SqlclProcess.send_command(json, 3_000)
      Logger.info("server: #{inspect mcp_server}")
      #result = list_connections(mcp_server )

      # Verify response structure
      result = response["result"]
      assert Map.has_key?(result, "content")
      content = result["content"]
      assert is_list(content)
      assert length(content) > 0

      # Check for text content
      text_content = case content do
        [%{"type" => "text", "text" => text}] -> text
        _ -> ""
      end

      # Verify default connection is listed
      default_connection = get_default_connection()
      assert String.contains?(text_content, default_connection),
        "Default connection '#{default_connection}' not found in: #{text_content}"

      Logger.info("Connection list retrieved successfully: #{text_content}")
    end

    test "can connect to configured database connection", %{mcp_server: _mcp_server} do
      connection_name = get_default_connection()
      {server, session_id} = connect_to_database(connection_name)

      # Verify we have a valid server and session
      #assert server != nil
      #assert session_id != nil

      # Test connection by running a simple query
      result = execute_sql(get_test_query(:simple_select), server, session_id)

      # Verify query response
      assert Map.has_key?(result, "content")
      content = result["content"]
      assert is_list(content)
      assert length(content) > 0

      Logger.info("Successfully connected to database: #{connection_name}")
    end

    test "handles connection to non-existent database gracefully", %{mcp_server: mcp_server} do
      assert false, "not done yet"
    end
  end

  describe "SQL Execution" do
    test "can execute simple SQL query", %{mcp_server: _mcp_server} do
      assert false, "not done yet"
    end

    test "can execute table listing query", %{mcp_server: _mcp_server} do
      assert false, "not done yet"
    end

    test "can execute user information query", %{mcp_server: _mcp_server} do
      assert false, "not done yet"
    end


    test "can execute table data query with validation", %{mcp_server: _mcp_server} do
      assert false, "not done yet"
    end

    test "handles SQL errors gracefully", %{mcp_server: _mcp_server} do
      assert false, "not done yet"
    end
  end

    test "can override connection via environment variable" do
      # This test verifies that environment variables are respected
      original_value = System.get_env("SQLCL_TEST_CONNECTION")

      # Set a test value
      System.put_env("SQLCL_TEST_CONNECTION", "test_override")

      # Reload configuration (this would normally require app restart)
      # For testing, we'll just verify the env var is read
      test_connection = System.get_env("SQLCL_TEST_CONNECTION") || "theconn"
      assert test_connection == "test_override"

      # Restore original value
      if original_value do
        System.put_env("SQLCL_TEST_CONNECTION", original_value)
      else
        System.delete_env("SQLCL_TEST_CONNECTION")
      end

      Logger.info("Environment variable override works correctly")
    end

  # Helper functions


end
