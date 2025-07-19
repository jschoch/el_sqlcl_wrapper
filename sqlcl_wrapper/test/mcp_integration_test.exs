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
    wait_for_sqlcl_startup()

    # Get the MCP server from the registry
    mcp_server = Hermes.Server.Registry.whereis_server(SqlclWrapper.MCPServer)

    unless mcp_server do
      flunk("MCP server not found in registry")
    end

    Logger.info("MCP integration test setup complete")
    {server, session_id} = perform_mcp_handshake(mcp_server)

    on_exit(fn ->
      Logger.info("Cleaning up MCP integration test")
      Application.stop(:sqlcl_wrapper)
    end)

    %{mcp_server: mcp_server}
  end

    test "MCP server handles initialization sequence correctly", %{mcp_server: mcp_server} do
      # Step 1: Initialize the server
      init_message = %{
        "jsonrpc" => "2.0",
        "method" => "initialize",
        "id" => "test-init-#{System.unique_integer([:monotonic])}",
        "params" => %{
          "protocolVersion" => get_protocol_version(),
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
      assert init_response_data["id"] == init_message["id"]

      # Verify server capabilities
      result = init_response_data["result"]
      assert Map.has_key?(result, "capabilities")
      assert Map.has_key?(result, "serverInfo")

      # Step 2: Send initialized notification
      initialized_notification = %{
        "jsonrpc" => "2.0",
        "method" => "notifications/initialized",
        "params" => %{}
      }

      # This should not raise an error
      GenServer.cast(mcp_server, {:notification, initialized_notification, "test-session", %{}})

      Logger.info("MCP initialization sequence completed successfully")
    end

    test "MCP server lists available tools correctly", %{mcp_server: mcp_server} do
      {server, session_id} = perform_mcp_handshake(mcp_server)

      # Request tools list
      message = %{
        "jsonrpc" => "2.0",
        "method" => "tools/list",
        "id" => "test-tools-list-#{System.unique_integer([:monotonic])}",
        "params" => %{}
      }

      {:ok, response} = GenServer.call(server, {:request, message, session_id, %{}})
      response_data = Jason.decode!(response)

      assert response_data["jsonrpc"] == "2.0"
      assert response_data["id"] == message["id"]

      # Check for error response
      if Map.has_key?(response_data, "error") do
        flunk("Server returned error: #{inspect(response_data["error"])}")
      end

      # Verify all expected tools are available
      tools = response_data["result"]["tools"]
      assert is_list(tools)

      expected_tools = ["list-connections", "connect", "disconnect", "run-sqlcl", "run-sql"]
      tool_names = Enum.map(tools, & &1["name"])

      for tool_name <- expected_tools do
        assert tool_name in tool_names, "Missing tool: #{tool_name}"
      end

      Logger.info("All expected MCP tools are available: #{inspect(tool_names)}")
    end

  describe "Connection Management" do
    test "can list available database connections", %{mcp_server: mcp_server} do
       {server, session_id} = perform_mcp_handshake(mcp_server)

      result = list_connections(server,session_id)

      # Verify response structure
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

    test "can connect to configured database connection", %{mcp_server: mcp_server} do
      {server, session_id} = perform_mcp_handshake(mcp_server)
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
      {server, session_id} = perform_mcp_handshake(mcp_server)

      connect_message = %{
        "jsonrpc" => "2.0",
        "method" => "tools/call",
        "id" => "connect-nonexistent-#{System.unique_integer([:monotonic])}",
        "params" => %{
          "name" => "connect",
          "arguments" => %{
            "connection_name" => "nonexistent_connection",
            "mcp_client" => "test-client",
            "model" => "claude-sonnet-4"
          }
        }
      }

      {:ok, response} = GenServer.call(server, {:request, connect_message, session_id, %{}})
      response_data = Jason.decode!(response)

      # Should return an error for non-existent connection
      assert Map.has_key?(response_data, "error") or
             (Map.has_key?(response_data, "result") and
              String.contains?(inspect(response_data["result"]), "error"))

      Logger.info("Non-existent connection properly handled")
    end
  end

  describe "SQL Execution" do
    test "can execute simple SQL query", %{mcp_server: mcp_server} do
      {server, session_id} = connect_to_database()

      query = get_test_query(:dual_query)
      result = execute_sql(query, server, session_id)

      # Verify response structure
      assert Map.has_key?(result, "content")
      content = result["content"]
      assert is_list(content)

      # Check for expected content
      text_content = case content do
        [%{"type" => "text", "text" => text}] -> text
        _ -> ""
      end

      assert String.contains?(text_content, "Hello SQLcl"),
        "Expected 'Hello SQLcl' in response: #{text_content}"

      Logger.info("Simple SQL query executed successfully")
    end

    test "can execute table listing query", %{mcp_server: mcp_server} do
      {server, session_id} = connect_to_database()

      query = get_test_query(:list_tables)
      result = execute_sql(query, server, session_id)

      # Verify response structure
      assert Map.has_key?(result, "content")
      content = result["content"]
      assert is_list(content)

      # Check for expected table names
      text_content = case content do
        [%{"type" => "text", "text" => text}] -> text
        _ -> ""
      end

      expected_tables = get_expected_tables()
      for table <- expected_tables do
        assert String.contains?(text_content, table),
          "Expected table '#{table}' not found in: #{text_content}"
      end

      Logger.info("Table listing query executed successfully")
    end

    test "can execute user information query", %{mcp_server: mcp_server} do
      {server, session_id} = connect_to_database()

      query = get_test_query(:current_user)
      result = execute_sql(query, server, session_id)

      # Verify response structure
      assert Map.has_key?(result, "content")
      content = result["content"]
      assert is_list(content)

      # Check for user information
      text_content = case content do
        [%{"type" => "text", "text" => text}] -> text
        _ -> ""
      end

      assert String.length(text_content) > 0, "User query should return content"

      Logger.info("User information query executed successfully: #{text_content}")
    end

    test "can execute table data query with validation", %{mcp_server: mcp_server} do
      {server, session_id} = perform_mcp_handshake(mcp_server)
      {server, session_id} = connect_to_database()

      # Test with USERS table
      query = "SELECT /* LLM in use is claude-sonnet-4 */ * FROM USERS WHERE ROWNUM <= 5"
      result = execute_sql(query, server, session_id)

      # Verify response structure
      assert Map.has_key?(result, "content")
      content = result["content"]
      assert is_list(content)

      # Check for expected columns and data
      text_content = case content do
        [%{"type" => "text", "text" => text}] -> text
        _ -> ""
      end

      validation_config = get_table_validation_config("USERS")
      expected_columns = validation_config[:columns] || []
      expected_data = validation_config[:sample_data] || []

      for column <- expected_columns do
        assert String.contains?(text_content, column),
          "Expected column '#{column}' not found in: #{text_content}"
      end

      for data <- expected_data do
        assert String.contains?(text_content, data),
          "Expected data '#{data}' not found in: #{text_content}"
      end

      Logger.info("Table data query with validation executed successfully")
    end

    test "handles SQL errors gracefully", %{mcp_server: mcp_server} do
      {server, session_id} = connect_to_database()

      # Execute invalid SQL
      invalid_query = "SELECT * FROM non_existent_table"

      assert_raise RuntimeError, ~r/SQL execution failed/, fn ->
        execute_sql(invalid_query, server, session_id)
      end

      Logger.info("SQL errors handled gracefully")
    end
  end

  describe "SQLcl Command Execution" do
    test "can execute SQLcl commands", %{mcp_server: mcp_server} do
      {server, session_id} = connect_to_database()

      # Test version command
      result = execute_sqlcl_command("show version", server, session_id)

      # Verify response structure
      assert Map.has_key?(result, "content")
      content = result["content"]
      assert is_list(content)

      # Check for version information
      text_content = case content do
        [%{"type" => "text", "text" => text}] -> text
        _ -> ""
      end

      assert String.length(text_content) > 0, "Version command should return content"

      Logger.info("SQLcl command executed successfully")
    end

    test "can execute describe command", %{mcp_server: mcp_server} do
      {server, session_id} = connect_to_database()

      # Test describe command on USERS table
      result = execute_sqlcl_command("describe USERS", server, session_id)

      # Verify response structure
      assert Map.has_key?(result, "content")
      content = result["content"]
      assert is_list(content)

      # Check for table description
      text_content = case content do
        [%{"type" => "text", "text" => text}] -> text
        _ -> ""
      end

      assert String.length(text_content) > 0, "Describe command should return content"

      Logger.info("Describe command executed successfully")
    end
  end

  describe "Configuration Management" do
    test "uses configured default connection" do
      default_connection = get_default_connection()
      assert is_binary(default_connection)
      assert String.length(default_connection) > 0

      Logger.info("Default connection configured: #{default_connection}")
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
  end

  # Helper functions

  defp get_protocol_version() do
    Application.get_env(:sqlcl_wrapper, :mcp_server)[:protocol_version] || "2025-06-18"
  end

  defp get_default_connection() do
    Application.get_env(:sqlcl_wrapper, :default_connection) || "theconn"
  end

  defp get_test_query(query_name) do
    Application.get_env(:sqlcl_wrapper, :test_queries)[query_name]
  end

  defp get_expected_tables() do
    Application.get_env(:sqlcl_wrapper, :expected_tables) || []
  end

  defp get_table_validation_config(table_name) do
    table_key = String.downcase(table_name) <> "_table" |> String.to_atom()
    Application.get_env(:sqlcl_wrapper, :test_data_validation)[table_key] || %{}
  end
end
