defmodule SqlclWrapper.SqlclTestProcessHelper do
  require Logger
  alias SqlclWrapper.SqlclProcess
  alias Jason

  require Logger
  alias SqlclWrapper.SqlclProcess
  alias Jason

  @doc """
  Starts an isolated SQLcl process and performs the necessary handshake and connection.
  Returns a tuple of {sqlcl_process_pid, unique_name}.
  """
  def start_sqlcl_process() do
    unique_name = :"sqlcl_test_#{System.unique_integer()}"
    Logger.info("Starting isolated SQLcl process with name: #{inspect(unique_name)}...")
    {:ok, sqlcl_process_pid} = SqlclProcess.start_link(parent: self(), name: unique_name)
    Logger.info("Isolated SqlclProcess started with PID: #{inspect(sqlcl_process_pid)} and name: #{inspect(unique_name)}")

    # Subscribe this process to SqlclProcess output to capture startup messages
    SqlclProcess.subscribe(sqlcl_process_pid, self())
    Process.sleep(100) # Give SqlclProcess a moment to register the subscriber

    # Wait for the SQLcl process to report ready
    wait_for_sqlcl_server_ready(sqlcl_process_pid, "", 30000) # Increased timeout to 30 seconds
    Logger.info("Isolated SQLcl process reported ready.")
    Process.sleep(1000) # Give SQLcl a moment to fully initialize after startup message

    Logger.info("Attempting to send initialize command to isolated SQLcl process...")
    {:ok, init_resp} = SqlclProcess.send_command(~s({"jsonrpc": "2.0", "method": "initialize", "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "my-stdio-client", "version": "1.0.0"}}, "id": 1}), sqlcl_process_pid)
    Logger.info("Received initialize response from isolated SQLcl process: #{inspect(init_resp)}")

    Logger.info("Attempting to send initialized notification to isolated SQLcl process...")
    SqlclProcess.send_command(~s({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}), sqlcl_process_pid)
    Logger.info("Initialized notification sent to isolated SQLcl process.")

    Logger.info("Attempting to connect to database using 'theconn' for isolated SQLcl process...")
    connect_command = %{
      jsonrpc: "2.0",
      id: 2,
      method: "tools/call",
      params: %{
        name: "connect",
        arguments: %{
          "connection_name" => "theconn",
          "model" => "claude-sonnet-4",
          "mcp_client" => "cline"
        }
      }
    } |> Jason.encode!()
    {:ok, connect_resp} = SqlclProcess.send_command(connect_command, sqlcl_process_pid)
    Logger.info("Received connect response from isolated SQLcl process: #{inspect(connect_resp)}")
    Process.sleep(1000) # Give SQLcl a moment to establish connection

    Logger.info("Isolated SQLcl process and database connection setup complete.")
    {sqlcl_process_pid, unique_name}
  end

  @doc """
  Helper to wait for the SQLcl process to report "MCP Server started successfully".
  """
  defp wait_for_sqlcl_server_ready(sqlcl_pid, buffer \\ "", timeout \\ 15000) do
    Logger.info("running wait for sqlcl_server_ready for PID: #{inspect(sqlcl_pid)}")
    receive do
      {:sqlcl_output, {:stdout, iodata}} ->
        new_buffer = buffer <> IO.iodata_to_binary(iodata)
        Logger.info("Received stdout chunk: #{inspect(iodata)}")
        if String.contains?(new_buffer, "----------------------------------------") do
          :ok
        else
          wait_for_sqlcl_server_ready(sqlcl_pid, new_buffer, timeout)
        end
      {:sqlcl_output, {:stderr, iodata}} ->
        new_buffer = buffer <> IO.iodata_to_binary(iodata)
        Logger.info("Received stderr chunk: #{inspect(iodata)}")
        if String.contains?(new_buffer, "----------------------------------------") do
          :ok
        else
          wait_for_sqlcl_server_ready(sqlcl_pid, new_buffer, timeout)
        end
      {:sqlcl_output, {:exit, _}} -> raise "SQLcl process exited prematurely during setup for PID: #{inspect(sqlcl_pid)}"
      _other_message -> # Catch any other messages that might be sent to self()
        wait_for_sqlcl_server_ready(sqlcl_pid, buffer, timeout)
    after timeout ->
      raise "Timeout waiting for SQLcl process to report 'MCP Server started successfully' for PID: #{inspect(sqlcl_pid)}. Buffer: #{buffer}"
    end
  end

  @doc """
  Function to start and manage an isolated SQLcl process for a test.
  This function is intended to be called directly from an ExUnit setup block.
  """
  def setup_sqlcl_process(context) do
    {sqlcl_pid, unique_name} = start_sqlcl_process()

    {:ok, Map.put(context, :sqlcl_pid, sqlcl_pid) |> Map.put(:sqlcl_name, unique_name)}
  end
end
