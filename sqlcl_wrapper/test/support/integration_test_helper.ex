defmodule SqlclWrapper.IntegrationTestHelper do
  require Logger
  alias SqlclWrapper.{MCPServer, SqlclProcess}

  @moduledoc """
  Provides comprehensive helper functions for SQLcl integration tests.
  Includes connection management, SQL execution, and test data validation.
  """

  @doc """
  Common setup for integration tests with configurable connection.
  """
  def do_setup_all(opts \\ %{}) do
    port = opts[:port] || 4000
    Logger.info("Setting up integration test environment on port #{port}")

    # Ensure the application is started
    {:ok, _apps} = Application.ensure_all_started(:sqlcl_wrapper)

    # Wait for SQLcl process to be ready
    wait_for_sqlcl_startup()

    Logger.info("Integration test environment ready")
    :ok
  end

  @doc """
  Waits for SQLcl process to be fully started and ready.
  """
  def wait_for_sqlcl_startup(retries \\ 30) do
    case Process.whereis(SqlclProcess) do
      nil when retries > 0 ->
        Process.sleep(500)
        wait_for_sqlcl_startup(retries - 1)
      nil ->
        Logger.error("SQLcl process failed to start after timeout")
        raise "SQLcl process not started"
      pid ->
        wait_for_server_ready(pid, retries)
    end
  end

  defp wait_for_server_ready(pid, retries) when retries > 0 do
    try do
      case GenServer.call(pid, :is_server_ready, 1000) do
        true ->
          Logger.info("SQLcl server is ready")
          :ok
        false ->
          Process.sleep(500)
          wait_for_server_ready(pid, retries - 1)
      end
    rescue
      _ ->
        Process.sleep(500)
        wait_for_server_ready(pid, retries - 1)
    end
  end

  defp wait_for_server_ready(_pid, 0) do
    Logger.error("SQLcl server did not become ready within timeout")
    raise "SQLcl server not ready"
  end

  @doc """
  Performs the complete MCP handshake sequence for a test client.
  """
  def perform_mcp_handshake(mcp_server) do
    session_id = "test-session-#{System.unique_integer([:monotonic])}"

    # Step 1: Initialize the session
    init_message = %{
      "jsonrpc" => "2.0",
      "method" => "initialize",
      "id" => "init-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "protocolVersion" => get_protocol_version(),
        "capabilities" => %{},
        "clientInfo" => %{
          "name" => "test-client",
          "version" => "1.0.0"
        }
      }
    }

    {:ok, init_response} = GenServer.call(mcp_server, {:request, init_message, session_id, %{}})
    init_data = Jason.decode!(init_response)

    unless init_data["jsonrpc"] == "2.0" and Map.has_key?(init_data, "result") do
      raise "MCP initialization failed: #{inspect(init_data)}"
    end

    # Step 2: Send initialized notification for the session
    initialized_notification = %{
      "jsonrpc" => "2.0",
      "method" => "notifications/initialized",
      "params" => %{}
    }

    GenServer.cast(mcp_server, {:notification, initialized_notification, session_id, %{}})

    Logger.info("Test client MCP handshake completed successfully for session: #{session_id}")
    {mcp_server, session_id}
  end

  @doc """
  Connects to the specified database connection.
  """
  def connect_to_database(connection_name \\ nil) do
    connection_name = connection_name || get_default_connection()

    case get_mcp_server() do
      nil -> raise "MCP server not available"
      mcp_server ->
        {server, session_id} = perform_mcp_handshake(mcp_server)

        connect_message = %{
          "jsonrpc" => "2.0",
          "method" => "tools/call",
          "id" => "connect-#{System.unique_integer([:monotonic])}",
          "params" => %{
            "name" => "connect",
            "arguments" => %{
              "connection_name" => connection_name,
              "mcp_client" => "test-client",
              "model" => "claude-sonnet-4"
            }
          }
        }

        #{:ok, response} = GenServer.call(server, {:request, connect_message, session_id, %{}})
        #response_data = Jason.decode!(response)
        _response = case GenServer.call(server, {:request, connect_message, session_id, %{}}) do
          {:ok, response} -> response
          bad ->
            Logger.info("bad response on database connection was: #{inspect bad}")
            %{"error" => :bad}
            raise "Bad #{inspect bad}"
        end


        Logger.info("Connected to database: #{connection_name}")
        {server, session_id}
    end
  end

  @doc """
  Executes a SQL query through the MCP server.
  """
  def execute_sql(sql_query, mcp_server \\ nil, session_id \\ nil) do
    {server, session} = case {mcp_server, session_id} do
      {nil, nil} ->
        {srv, sid} = connect_to_database()
        {srv, sid}
      {srv, sid} -> {srv, sid}
    end

    sql_message = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => "sql-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "name" => "run-sql",
        "arguments" => %{
          "sql" => sql_query,
          "mcp_client" => "cline",
          "model" => "mememe"
        }
      }
    }

    {:ok, response} = GenServer.call(server, {:request, sql_message, session, %{}})
    response_data = Jason.decode!(response)

    if Map.has_key?(response_data, "error") do
      raise "SQL execution failed: #{inspect(response_data["error"])}"
    end

    response_data["result"]
  end

  @doc """
  Executes a SQLcl command through the MCP server.
  """
  def execute_sqlcl_command(command, mcp_server \\ nil, session_id \\ nil) do
    {server, session} = case {mcp_server, session_id} do
      {nil, nil} ->
        {srv, sid} = connect_to_database()
        {srv, sid}
      {srv, sid} -> {srv, sid}
    end

    command_message = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => "sqlcl-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "name" => "run-sqlcl",
        "arguments" => %{
          "sqlcl" => command,
          "mcp_client" => "test-client",
          "model" => "claude-sonnet-4"
        }
      }
    }

    {:ok, response} = GenServer.call(server, {:request, command_message, session, %{}})
    response_data = Jason.decode!(response)

    if Map.has_key?(response_data, "error") do
      Logger.info("Pre crash: #{inspect response_data, pretty: true}")
      raise "SQLcl command failed: #{inspect(response_data["error"])}"
    end

    response_data["result"]
  end

   @doc """
  Lists available database connections through the MCP server.
  """
  def list_connections(mcp_server, session_id) do
    list_connections_message = %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => "list-connections-#{System.unique_integer([:monotonic])}",
      "params" => %{
        "name" => "list-connections",
        "arguments" => %{
          "mcp_client" => "test-client",
          "model" => "claude-sonnet-4"
        }
      }
    }

    {:ok, response} = GenServer.call(mcp_server, {:request, list_connections_message, session_id, %{}})
    response_data = Jason.decode!(response)

    if Map.has_key?(response_data, "error") do
      raise "List connections failed: #{inspect(response_data["error"])}"
    end

    response_data["result"]
  end

  @doc """
  Validates that expected test tables exist in the database.
  """
  def validate_test_tables(mcp_server \\ nil, session_id \\ nil) do
    {server, session} = case {mcp_server, session_id} do
      {nil, nil} -> connect_to_database()
      {srv, sid} -> {srv, sid}
    end

    query = get_test_query(:list_tables)
    result = execute_sql(query, server, session)

    expected_tables = get_expected_tables()
    validate_table_existence(result, expected_tables)
  end

  @doc """
  Validates specific table structure and data.
  """
  def validate_table_data(table_name, mcp_server \\ nil, session_id \\ nil) do
    {server, session} = case {mcp_server, session_id} do
      {nil, nil} -> connect_to_database()
      {srv, sid} -> {srv, sid}
    end

    query = "SELECT /* LLM in use is claude-sonnet-4 */ * FROM #{table_name}"
    result = execute_sql(query, server, session)

    validation_config = get_table_validation_config(table_name)
    validate_table_structure(result, validation_config)
  end

  @doc """
  Builds a JSON-RPC tool call message.
  """
  def build_json_rpc_tool_call(id, tool_name, arguments, include_model \\ true) do
    base_args = if include_model do
      %{"mcp_client" => "test-client", "model" => "claude-sonnet-4"}
    else
      %{}
    end

    args = case arguments do
      args when is_map(args) -> Map.merge(base_args, args)
      args when is_binary(args) -> Map.merge(base_args, %{"sql" => args})
      _ -> base_args
    end

    %{
      "jsonrpc" => "2.0",
      "method" => "tools/call",
      "id" => id,
      "params" => %{
        "name" => tool_name,
        "arguments" => args
      }
    }
    |> Jason.encode!()
  end

  @doc """
  Builds a JSON-RPC connect call message.
  """
  def build_json_rpc_connect_call(id, connection_name) do
    build_json_rpc_tool_call(id, "connect", %{
      "connection_name" => connection_name,
      "mcp_client" => "test-client",
      "model" => "claude-sonnet-4"
    })
  end

  @doc """
  Receives and processes Server-Sent Events (SSE) messages.
  """
  def receive_sse_messages(async_id, messages \\ [], timeout \\ 5000) do
    receive do
      %HTTPoison.AsyncStatus{id: ^async_id, code: 200} ->
        receive_sse_messages(async_id, messages, timeout)
      %HTTPoison.AsyncHeaders{id: ^async_id} ->
        receive_sse_messages(async_id, messages, timeout)
      %HTTPoison.AsyncChunk{id: ^async_id, chunk: chunk} ->
        receive_sse_messages(async_id, [chunk | messages], timeout)
      %HTTPoison.AsyncEnd{id: ^async_id} ->
        Enum.reverse(messages)
    after
      timeout ->
        Logger.warning("SSE message timeout after #{timeout}ms")
        Enum.reverse(messages)
    end
  end

  # Private helper functions

  defp get_mcp_server() do
    Hermes.Server.Registry.whereis_server(MCPServer)
  end

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

  defp validate_table_existence(result, expected_tables) do
    content = result["content"]
    text_content = case content do
      [%{"type" => "text", "text" => text}] -> text
      _ -> ""
    end

    missing_tables = expected_tables
    |> Enum.reject(fn table -> String.contains?(text_content, table) end)

    if Enum.empty?(missing_tables) do
      Logger.info("All expected tables found: #{inspect(expected_tables)}")
      :ok
    else
      Logger.error("Missing tables: #{inspect(missing_tables)}")
      {:error, {:missing_tables, missing_tables}}
    end
  end

  defp validate_table_structure(result, validation_config) do
    content = result["content"]
    text_content = case content do
      [%{"type" => "text", "text" => text}] -> text
      _ -> ""
    end

    expected_columns = validation_config[:columns] || []
    expected_data = validation_config[:sample_data] || []

    missing_columns = expected_columns
    |> Enum.reject(fn column -> String.contains?(text_content, column) end)

    missing_data = expected_data
    |> Enum.reject(fn data -> String.contains?(text_content, data) end)

    cond do
      not Enum.empty?(missing_columns) ->
        Logger.error("Missing columns: #{inspect(missing_columns)}")
        {:error, {:missing_columns, missing_columns}}
      not Enum.empty?(missing_data) ->
        Logger.error("Missing sample data: #{inspect(missing_data)}")
        {:error, {:missing_data, missing_data}}
      true ->
        Logger.info("Table structure validation passed")
        :ok
    end
  end
end
