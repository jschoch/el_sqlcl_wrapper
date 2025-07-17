defmodule SqlclWrapper.SseClientMessageTest do
  use ExUnit.Case, async: false
  import SqlclWrapper.IntegrationTestHelper
  require Logger
  require HTTPoison

  @moduledoc """
  Tests for Server-Sent Events (SSE) functionality with enhanced configuration management.
  """

  @port 4001
  @url "http://localhost:#{@port}/tool"

  setup_all do
    do_setup_all(%{port: @port, url: @url, initialize_mcp: false})

    on_exit(fn ->
      if pid = Process.whereis(SqlclWrapper.SqlclProcess) do
        Logger.info("Shutting down SQLcl process after SSE client message test suite.")
        Process.exit(pid, :kill)
      end
    end)
    :ok
  end

  describe "SSE SQL Query Testing" do
    test "SSE client receives expected message from configured SQL query" do
      connection_name = get_default_connection()

      # First connect to the configured database connection
      connect_command = build_json_rpc_connect_call(100, connection_name)
      Logger.info("Connecting to database: #{connection_name}")

      {:ok, %HTTPoison.AsyncResponse{id: connect_id}} =
        HTTPoison.post(@url, connect_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Collect connection response
      connect_messages = receive_sse_messages(connect_id, [], 3000)
      Logger.info("Connection response: #{inspect(connect_messages)}")

      # Now send a SQL query using configured test query
      test_query = get_test_query(:dual_query)
      json_rpc_command = build_json_rpc_tool_call(101, "run-sql", %{"sql" => test_query})
      Logger.info("Executing SQL query: #{test_query}")

      # Send the SQL query command
      {:ok, %HTTPoison.AsyncResponse{id: async_id}} =
        HTTPoison.post(@url, json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Collect SSE messages
      received_messages = receive_sse_messages(async_id, [], 5000)
      Logger.info("SSE client received messages: #{inspect(received_messages)}")

      # Verify we received some messages
      assert is_list(received_messages)
      assert length(received_messages) > 0

      # Check that the response contains expected content
      combined_message = Enum.join(received_messages, " ")
      assert String.contains?(combined_message, "Hello SQLcl"),
        "Expected 'Hello SQLcl' in SSE response: #{combined_message}"
    end

    test "SSE client receives table listing via configured query" do
      connection_name = get_default_connection()

      # Connect to database
      connect_command = build_json_rpc_connect_call(102, connection_name)
      {:ok, %HTTPoison.AsyncResponse{id: connect_id}} =
        HTTPoison.post(@url, connect_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Wait for connection
      _connect_messages = receive_sse_messages(connect_id, [], 3000)

      # Send table listing query
      list_tables_query = get_test_query(:list_tables)
      json_rpc_command = build_json_rpc_tool_call(103, "run-sql", %{"sql" => list_tables_query})
      Logger.info("Executing table listing query: #{list_tables_query}")

      {:ok, %HTTPoison.AsyncResponse{id: async_id}} =
        HTTPoison.post(@url, json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Collect SSE messages
      received_messages = receive_sse_messages(async_id, [], 5000)
      Logger.info("Table listing SSE response: #{inspect(received_messages)}")

      # Verify we received table listing
      assert is_list(received_messages)
      assert length(received_messages) > 0

      # Check for expected table names from configuration
      combined_message = Enum.join(received_messages, " ")
      expected_tables = get_expected_tables()

      # At least one expected table should be in the response
      has_expected_table = Enum.any?(expected_tables, fn table ->
        String.contains?(combined_message, table)
      end)

      assert has_expected_table,
        "Expected at least one table from #{inspect(expected_tables)} in response: #{combined_message}"
    end

    test "SSE client handles user table query with validation" do
      connection_name = get_default_connection()

      # Connect to database
      connect_command = build_json_rpc_connect_call(104, connection_name)
      {:ok, %HTTPoison.AsyncResponse{id: connect_id}} =
        HTTPoison.post(@url, connect_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Wait for connection
      _connect_messages = receive_sse_messages(connect_id, [], 3000)

      # Query USERS table with validation
      users_query = "SELECT /* LLM in use is claude-sonnet-4 */ * FROM USERS WHERE ROWNUM <= 3"
      json_rpc_command = build_json_rpc_tool_call(105, "run-sql", %{"sql" => users_query})
      Logger.info("Executing users table query: #{users_query}")

      {:ok, %HTTPoison.AsyncResponse{id: async_id}} =
        HTTPoison.post(@url, json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Collect SSE messages
      received_messages = receive_sse_messages(async_id, [], 5000)
      Logger.info("Users table SSE response: #{inspect(received_messages)}")

      # Verify we received user data
      assert is_list(received_messages)
      assert length(received_messages) > 0

      # Validate against configuration
      combined_message = Enum.join(received_messages, " ")
      validation_config = get_table_validation_config("USERS")
      expected_columns = validation_config[:columns] || []
      expected_data = validation_config[:sample_data] || []

      # Check for expected columns
      columns_found = Enum.filter(expected_columns, fn column ->
        String.contains?(combined_message, column)
      end)

      assert length(columns_found) > 0,
        "Expected at least one column from #{inspect(expected_columns)} in response: #{combined_message}"

      # Check for expected data
      data_found = Enum.filter(expected_data, fn data ->
        String.contains?(combined_message, data)
      end)

      assert length(data_found) > 0,
        "Expected at least one data entry from #{inspect(expected_data)} in response: #{combined_message}"
    end

    test "SSE client handles SQLcl commands properly" do
      connection_name = get_default_connection()

      # Connect to database
      connect_command = build_json_rpc_connect_call(106, connection_name)
      {:ok, %HTTPoison.AsyncResponse{id: connect_id}} =
        HTTPoison.post(@url, connect_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Wait for connection
      _connect_messages = receive_sse_messages(connect_id, [], 3000)

      # Execute SQLcl command
      sqlcl_command = build_json_rpc_tool_call(107, "run-sqlcl", %{"sqlcl" => "show version"})
      Logger.info("Executing SQLcl command: show version")

      {:ok, %HTTPoison.AsyncResponse{id: async_id}} =
        HTTPoison.post(@url, sqlcl_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Collect SSE messages
      received_messages = receive_sse_messages(async_id, [], 5000)
      Logger.info("SQLcl command SSE response: #{inspect(received_messages)}")

      # Verify we received command output
      assert is_list(received_messages)
      assert length(received_messages) > 0

      # Check that we got some version information
      combined_message = Enum.join(received_messages, " ")
      assert String.length(combined_message) > 0,
        "SQLcl command should return some output"
    end
  end

  describe "SSE Error Handling" do
    test "SSE client handles invalid SQL gracefully" do
      connection_name = get_default_connection()

      # Connect to database
      connect_command = build_json_rpc_connect_call(108, connection_name)
      {:ok, %HTTPoison.AsyncResponse{id: connect_id}} =
        HTTPoison.post(@url, connect_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Wait for connection
      _connect_messages = receive_sse_messages(connect_id, [], 3000)

      # Send invalid SQL
      invalid_sql = "SELECT * FROM non_existent_table_xyz"
      json_rpc_command = build_json_rpc_tool_call(109, "run-sql", %{"sql" => invalid_sql})
      Logger.info("Executing invalid SQL: #{invalid_sql}")

      {:ok, %HTTPoison.AsyncResponse{id: async_id}} =
        HTTPoison.post(@url, json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Collect SSE messages
      received_messages = receive_sse_messages(async_id, [], 5000)
      Logger.info("Invalid SQL SSE response: #{inspect(received_messages)}")

      # Verify we received error messages
      assert is_list(received_messages)
      assert length(received_messages) > 0

      # Check that we got error information
      combined_message = Enum.join(received_messages, " ")
      assert String.contains?(combined_message, "error") or
             String.contains?(combined_message, "ERROR") or
             String.contains?(combined_message, "not found") or
             String.contains?(combined_message, "does not exist"),
        "Expected error message in response: #{combined_message}"
    end

    test "SSE client handles connection errors gracefully" do
      # Try to connect to non-existent connection
      invalid_connection = "non_existent_connection_xyz"
      connect_command = build_json_rpc_connect_call(110, invalid_connection)
      Logger.info("Attempting to connect to invalid connection: #{invalid_connection}")

      {:ok, %HTTPoison.AsyncResponse{id: async_id}} =
        HTTPoison.post(@url, connect_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Collect SSE messages
      received_messages = receive_sse_messages(async_id, [], 5000)
      Logger.info("Invalid connection SSE response: #{inspect(received_messages)}")

      # Verify we received error messages
      assert is_list(received_messages)
      assert length(received_messages) > 0

      # Check that we got error information
      combined_message = Enum.join(received_messages, " ")
      assert String.contains?(combined_message, "error") or
             String.contains?(combined_message, "ERROR") or
             String.contains?(combined_message, "not found") or
             String.contains?(combined_message, "invalid"),
        "Expected error message for invalid connection: #{combined_message}"
    end
  end

  describe "SSE Performance and Reliability" do
    test "SSE client can handle multiple rapid requests" do
      connection_name = get_default_connection()

      # Connect to database
      connect_command = build_json_rpc_connect_call(111, connection_name)
      {:ok, %HTTPoison.AsyncResponse{id: connect_id}} =
        HTTPoison.post(@url, connect_command, [{"Content-Type", "application/json"}], stream_to: self())

      # Wait for connection
      _connect_messages = receive_sse_messages(connect_id, [], 3000)

      # Send multiple rapid queries
      test_query = get_test_query(:simple_select)
      async_ids = for i <- 1..3 do
        json_rpc_command = build_json_rpc_tool_call(112 + i, "run-sql", %{"sql" => test_query})
        {:ok, %HTTPoison.AsyncResponse{id: async_id}} =
          HTTPoison.post(@url, json_rpc_command, [{"Content-Type", "application/json"}], stream_to: self())
        async_id
      end

      # Collect all responses
      all_responses = Enum.map(async_ids, fn async_id ->
        receive_sse_messages(async_id, [], 3000)
      end)

      Logger.info("Multiple rapid requests responses: #{inspect(all_responses)}")

      # Verify all requests got responses
      assert length(all_responses) == 3

      # Verify each response has content
      for response <- all_responses do
        assert is_list(response)
        assert length(response) > 0
      end
    end
  end

  # Helper functions using the new configuration system

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
