defmodule SqlclWrapper.SqlclTestProcessHelper do
  require Logger
  alias SqlclWrapper.SqlclProcess

  @doc """
  Starts an isolated SQLcl process.
  Returns the PID of the SQLcl process.
  """
  def start_sqlcl_process() do
    unique_name = :"sqlcl_test_#{System.unique_integer()}"
    Logger.info("Starting isolated SQLcl process with name: #{inspect(unique_name)}...")
    {:ok, sqlcl_process_pid} = SqlclProcess.start_link(parent: self(), name: unique_name)
    Logger.info("Isolated SqlclProcess started with PID: #{inspect(sqlcl_process_pid)} and name: #{inspect(unique_name)}")
    Process.sleep(100) # Give SQLcl a moment to fully initialize
    sqlcl_process_pid
  end

  @doc """
  Function to start and manage an isolated SQLcl process for a test.
  This function is intended to be called directly from an ExUnit setup block.
  """
  def setup_sqlcl_process(context) do
    sqlcl_pid = start_sqlcl_process()
    {:ok, Map.put(context, :sqlcl_pid, sqlcl_pid)}
  end
end
