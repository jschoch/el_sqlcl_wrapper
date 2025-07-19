defmodule SqlclWrapper.SqlclProcess do
  use GenServer
  require Logger

  @sqlcl_path Application.compile_env(:sqlcl_wrapper, :sqlcl_executable, "sql.exe")

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    parent = Keyword.get(opts, :parent)
    Logger.info("Starting SQLcl process...")
    Logger.info("SQLcl executable path: #{@sqlcl_path}")

    try do
      # Redirect stderr to stdout so we can capture both streams
      port = Port.open({:spawn, "#{@sqlcl_path} -mcp 2>&1"}, [:binary, :exit_status])
      Logger.info("Port.open successful, Port: #{inspect(port)}")
      send(parent, {:sqlcl_process_started, self()})

      {:ok, %{port: port, parent: parent, request_map: %{}, server_ready_flag: false, stdout_buffer: ""}}
    catch
      error ->
        Logger.error("Port.open failed: #{inspect(error)}. Check if '#{@sqlcl_path}' is a valid executable and accessible.")
        send(parent, :sqlcl_process_failed_to_start)
        {:stop, :sqlcl_process_failed_to_start}
    end
  end

  @impl true
  def handle_call(:is_server_ready, _from, state) do
    {:reply, state.server_ready_flag, state}
  end

  @impl true
  def handle_call({:send_command, command}, from, state) do
    # If it's a JSON-RPC command, extract ID and store 'from'
    case Jason.decode(command) do
      {:ok, %{"id" => id} = _parsed_command} ->
        new_request_map = Map.put(state.request_map, id, from)
        Logger.info("Attempting to send JSON-RPC command to SQLcl process: #{command}")
        Port.command(state.port, command <> "\n")
        Logger.info("JSON-RPC command sent to SQLcl process.")
        {:noreply, %{state | request_map: new_request_map}}
      {:ok, _parsed_command} -> # JSON but no ID, treat as raw command
        Logger.info("Attempting to send raw command (JSON, no ID) to SQLcl process: #{command}")
        Port.command(state.port, command <> "\n")
        Logger.info("Raw command (JSON, no ID) sent to SQLcl process.")
        GenServer.reply(from, :ok) # Acknowledge receipt for raw commands
        {:noreply, state}
      _ ->
        # It's a raw command (not JSON), no ID to track, just send it
        Logger.info("Attempting to send raw command to SQLcl process: #{command}")
        Port.command(state.port, command <> "\n")
        Logger.info("Raw command sent to SQLcl process.")
        GenServer.reply(from, :ok) # Acknowledge receipt for raw commands
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_notification, notification}, state) do
    Logger.info("Attempting to send notification to SQLcl process: #{notification}")
    Port.command(state.port, notification <> "\n")
    Logger.info("Notification sent to SQLcl process.")
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:exit_status, status}}, state) when port == state.port do
    Logger.info("SQLcl process exited with status: #{inspect(status)}")
    send(state.parent, {:sqlcl_output, {:exit, status}})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when port == state.port do
    Logger.debug("[#{DateTime.utc_now()}] \t#{inspect(data)}")
    send(state.parent, {:sqlcl_output, {:stdout, data}})
    process_output(data, state)
  end

  @impl true
  def handle_info(msg, state) do
    Logger.info("[#{DateTime.utc_now()}] ***** Received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.port do
      Port.close(state.port)
    end
    :ok
  end

  defp process_output(data, state) do
    # Accumulate stdout/stderr data into a single buffer for readiness check
    current_buffer = state.stdout_buffer <> IO.iodata_to_binary(data)
    #Logger.info("[#{DateTime.utc_now()}] Current combined buffer: \"#{current_buffer}\"")
    #Logger.info("[#{DateTime.utc_now()}] Buffer length: #{String.length(current_buffer)}")

    # Check for server ready message in the accumulated buffer using multiple patterns
    patterns_to_check = [
      "----------------------------------------",
      "MCP Server started successfully",
      "Press Ctrl+C to stop the server"
    ]

    is_ready = Enum.any?(patterns_to_check, fn pattern ->
      contains_pattern = String.contains?(current_buffer, pattern)
      #Logger.info("[#{DateTime.utc_now()}] Checking pattern \"#{pattern}\": #{contains_pattern}")
      contains_pattern
    end)

    Logger.info("[#{DateTime.utc_now()}] Overall server ready check: #{is_ready}")

    new_state = if not state.server_ready_flag and is_ready do
      Logger.info("[#{DateTime.utc_now()}] SQLcl server reported ready. Setting server_ready_flag to true.")
      %{state | server_ready_flag: true, stdout_buffer: ""} # Clear buffer on ready
    else
      %{state | stdout_buffer: current_buffer} # Update buffer
    end

    # Attempt to parse the data as JSON and reply to the specific caller if it's a JSON-RPC response with an ID
    # This part remains specific to JSON-RPC responses, which are expected on stdout.
    # If the JSON-RPC response can also come on stderr, this logic would need to be duplicated or refactored.
    case Jason.decode(IO.iodata_to_binary(data)) do # Decode only the current data chunk for JSON-RPC
      {:ok, %{"jsonrpc" => "2.0", "id" => id} = json_response} ->
        if from = Map.get(new_state.request_map, id) do
          GenServer.reply(from, {:ok, json_response})
          {:noreply, %{new_state | request_map: Map.delete(new_state.request_map, id)}}
        else
          {:noreply, new_state} # No matching request, just broadcasted
        end
      {:ok, _other_json_response} ->
        {:noreply, new_state} # Not a JSON-RPC response with an ID, just broadcasted
      _ ->
        {:noreply, new_state} # Not valid JSON, just broadcasted
    end
  end

  # Client API
  def send_command(command, timeout \\ 5000) do # Default timeout of 5 seconds
    # Attempt to parse as JSON to determine if it's a request or notification
    case Jason.decode(command) do
      {:ok, %{"id" => _id} = _parsed_command} ->
        GenServer.call(__MODULE__, {:send_command, command}, timeout)
      {:ok, _parsed_command} -> # JSON but no ID, treat as a notification
        GenServer.cast(__MODULE__, {:send_notification, command})
      _ ->
        # Not JSON, treat as a raw command (e.g., "exit", "show release")
        GenServer.call(__MODULE__, {:send_command, command}, timeout)
    end
  end
end
