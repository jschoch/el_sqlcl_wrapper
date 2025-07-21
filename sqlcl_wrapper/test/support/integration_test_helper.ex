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

  @doc """
  Connects to the specified database connection.
  """
  def connect_to_database(connection_name \\ nil) do
    connection_name = connection_name || get_default_connection()

    raise "TODO: this doesn't quite work with the refactoring"
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
  Executes a SQLcl command through the MCP server.
  """
  def execute_sqlcl_command(command, mcp_server \\ nil, session_id \\ nil) do

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

    raise "we don't know how to do this quite yet: TODO"
    response_data = Jason.decode!(response)

    if Map.has_key?(response_data, "error") do
      Logger.info("Pre crash: #{inspect response_data, pretty: true}")
      raise "SQLcl command failed: #{inspect(response_data["error"])}"
    end

    response_data["result"]
  end

  @doc """
  Validates that expected test tables exist in the database.
  """
  def validate_test_tables(mcp_server \\ nil, session_id \\ nil) do

    query = get_test_query(:list_tables)
    result = execute_sql(query, server, session)

    expected_tables = get_expected_tables()
    validate_table_existence(result, expected_tables)
  end

  @doc """
  Validates specific table structure and data.
  """
  def validate_table_data(table_name, mcp_server \\ nil, session_id \\ nil) do

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


  def get_default_connection() do
    Application.get_env(:sqlcl_wrapper, :default_connection) || "theconn"
  end

  def get_test_query(query_name) do
    Application.get_env(:sqlcl_wrapper, :test_queries)[query_name]
  end

  def get_expected_tables() do
    Application.get_env(:sqlcl_wrapper, :expected_tables) || []
  end

  def get_table_validation_config(table_name) do
    table_key = String.downcase(table_name) <> "_table" |> String.to_atom()
    Application.get_env(:sqlcl_wrapper, :test_data_validation)[table_key] || %{}
  end

  # Private helper functions

  defp get_mcp_server() do
    Hermes.Server.Registry.whereis_server(MCPServer)
  end

  defp get_protocol_version() do
    Application.get_env(:sqlcl_wrapper, :mcp_server)[:protocol_version] || "2025-06-18"
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
