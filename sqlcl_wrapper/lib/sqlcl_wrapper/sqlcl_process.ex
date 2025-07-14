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

    case Porcelain.spawn(@sqlcl_path, ["-mcp"], out: {:send, self()}, err: {:send, self()}) do
      %Porcelain.Process{} = p ->
        send(parent, {:sqlcl_process_started, self()})
        {:ok, %{porcelain_pid: p, parent: parent, subscribers: [], request_map: %{}, next_id: 1}}

      _ ->
        Logger.error("Failed to start SQLcl process. Check if '#{@sqlcl_path}' is a valid executable and accessible.")
        send(parent, :sqlcl_process_failed_to_start)
        {:stop, :sqlcl_process_failed_to_start}
    end
  end

  @impl true
  def handle_call({:send_command, command}, from, state) do
    # If it's a JSON-RPC command, extract ID and store 'from'
    case Jason.decode(command) do
      {:ok, %{"id" => id} = _parsed_command} ->
        new_request_map = Map.put(state.request_map, id, from)
        Logger.info("Attempting to send JSON-RPC command to SQLcl process: #{command}")
        Porcelain.Process.send_input(state.porcelain_pid, command <> "\n")
        Logger.info("JSON-RPC command sent to SQLcl process.")
        {:noreply, %{state | request_map: new_request_map}}
      {:ok, _parsed_command} -> # JSON but no ID, treat as raw command
        Logger.info("Attempting to send raw command (JSON, no ID) to SQLcl process: #{command}")
        Porcelain.Process.send_input(state.porcelain_pid, command <> "\n")
        Logger.info("Raw command (JSON, no ID) sent to SQLcl process.")
        GenServer.reply(from, :ok) # Acknowledge receipt for raw commands
        {:noreply, state}
      _ ->
        # It's a raw command (not JSON), no ID to track, just send it
        Logger.info("Attempting to send raw command to SQLcl process: #{command}")
        Porcelain.Process.send_input(state.porcelain_pid, command <> "\n")
        Logger.info("Raw command sent to SQLcl process.")
        GenServer.reply(from, :ok) # Acknowledge receipt for raw commands
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:send_notification, notification}, state) do
    Logger.info("Attempting to send notification to SQLcl process: #{notification}")
    Porcelain.Process.send_input(state.porcelain_pid, notification <> "\n")
    Logger.info("Notification sent to SQLcl process.")
    {:noreply, state}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    {:noreply, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_cast({:send_command_async, command}, state) do
    Logger.info("Attempting to send async command to SQLcl process: #{command}")
    Porcelain.Process.send_input(state.porcelain_pid, command <> "\n")
    Logger.info("Async command sent to SQLcl process.")
    {:noreply, state}
  end

  @impl true
  def handle_info({:exit_status, status}, state) do
    Logger.info("SQLcl process exited with status: #{inspect(status)}")
    send(state.parent, {:sqlcl_output, {:exit, status}})
    {:stop, :normal, state}
  end

  @impl true
  def handle_info({_pid, :data, :out, data}, state) do
    Logger.info("[#{DateTime.utc_now()}] ***** SQLcl STDOUT: #{data}")
    Logger.info("[#{DateTime.utc_now()}] SqlclProcess attempting to send output to parent and subscribers.")
    # Always send raw data to parent and subscribers
    send(state.parent, {:sqlcl_output, {:stdout, data}})
    for pid <- state.subscribers do
      send(pid, {:sqlcl_output, {:stdout, data}})
    end

    # Attempt to parse the data as JSON and reply to the specific caller if it's a JSON-RPC response with an ID
    case Jason.decode(data) do
      {:ok, %{"jsonrpc" => "2.0", "id" => id} = json_response} ->
        if from = Map.get(state.request_map, id) do
          GenServer.reply(from, {:ok, json_response})
          {:noreply, %{state | request_map: Map.delete(state.request_map, id)}}
        else
          {:noreply, state} # No matching request, just broadcasted
        end
      {:ok, _other_json_response} ->
        {:noreply, state} # Not a JSON-RPC response with an ID, just broadcasted
      _ ->
        {:noreply, state} # Not valid JSON, just broadcasted
    end
  end

  @impl true
  def handle_info({_pid, :data, :err, data}, state) do
    Logger.error("[#{DateTime.utc_now()}] ***** SQLcl STDERR: #{data}")
    send(state.parent, {:sqlcl_output, {:stderr, data}})
    {:noreply, state}
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

  def subscribe(pid) do
    GenServer.cast(__MODULE__, {:subscribe, pid})
  end

  # Client API for commands that don't require an immediate reply to the caller
  def send_command_async(command) do
    GenServer.cast(__MODULE__, {:send_command_async, command})
  end
end
