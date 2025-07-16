defmodule SqlclWrapper.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.configure(level: :debug) # Ensure debug logging is enabled
    Logger.info("start called bigboy")
    children = [
      Hermes.Server.Registry,
      {SqlclWrapper.SqlclProcess, parent: self()}
    ]

    # Start the supervisor
    opts = [strategy: :one_for_one, name: SqlclWrapper.Supervisor]
    {:ok, pid} = Supervisor.start_link(children, opts)

    # Wait for SqlclProcess to signal it's ready
    wait_for_sqlcl_process_and_server_ready(3000) # 3 second timeout

    # Once SqlclProcess is ready, start MCPServer and Plug.Cowboy
    Supervisor.start_child(pid, {SqlclWrapper.MCPServer, transport: {:streamable_http, port: 4000}})
    Supervisor.start_child(pid, Plug.Cowboy.child_spec(scheme: :http, plug: {Hermes.Server.Transport.StreamableHTTP.Plug, server: SqlclWrapper.MCPServer}, options: [port: 4000]))

    {:ok, pid}
  end

  defp wait_for_sqlcl_process_and_server_ready(timeout \\ 3000) do
    start_time = System.monotonic_time(:millisecond)
    Logger.info("Waiting for SQLcl process to start and signal server ready...")

    # Wait for the initial :sqlcl_process_started message
    receive do
      {:sqlcl_process_started, _pid} ->
        Logger.info("Received :sqlcl_process_started message.")
      :sqlcl_process_failed_to_start ->
        Logger.error("SQLcl process failed to start. Aborting application startup.")
        exit(:sqlcl_process_failed_to_start)
    after timeout ->
      Logger.error("Timeout waiting for SQLcl process to start.")
      exit(:sqlcl_process_startup_timeout)
    end

    # Poll SqlclProcess until it reports server_ready_flag is true
    wait_for_sqlcl_server_ready(timeout - (System.monotonic_time(:millisecond) - start_time))
  end

  defp wait_for_sqlcl_server_ready(remaining_timeout) when remaining_timeout > 0 do
    Logger.info("Polling SqlclProcess for server readiness...")
    case GenServer.call(SqlclWrapper.SqlclProcess, :is_server_ready, 1000) do # 1 second timeout for the call
      true ->
        Logger.info("SQLcl server is ready.")
        :ok
      false ->
        Process.sleep(100) # Wait a bit before polling again
        wait_for_sqlcl_server_ready(remaining_timeout - 100)
      _ -> # In case of an error or unexpected response from GenServer.call
        Logger.error("Unexpected response from SqlclProcess when checking readiness.")
        exit(:sqlcl_readiness_check_error)
    end
  rescue
    e in [ArgumentError] -> # Catch if SqlclProcess is not yet started or crashes
      Logger.error("SqlclProcess not available or crashed during readiness check: #{inspect(e)}")
      Process.sleep(100)
      wait_for_sqlcl_server_ready(remaining_timeout - 100)
    e -> # Catch any other unexpected errors
      Logger.error("An unexpected error occurred during readiness check: #{inspect(e)}")
      exit(:sqlcl_readiness_check_error)
  end

  defp wait_for_sqlcl_server_ready(_remaining_timeout) do
    Logger.error("Timeout waiting for SQLcl server to become ready.")
    exit(:sqlcl_server_ready_timeout)
  end
end
