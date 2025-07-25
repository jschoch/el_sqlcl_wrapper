import Config

# Import the comprehensive test configuration
import_config "test_config.exs"

# Test-specific overrides
config :sqlcl_wrapper,
  # Use shorter timeouts for tests
  test_timeout: 10_000,
  connection_timeout: 5_000,

  # Enable debug logging for tests
  log_level: :debug,

  # Disable parallel tests for stability
  test_async: false

# Configure ExUnit
config :ex_unit,
  capture_log: true,
  assert_receive_timeout: 1_000

# Configure logger for tests
config :logger, :console,
  format: "[$level] $message\n",
  metadata: [:file, :line],
  level: :debug

# Test environment marker
config :sqlcl_wrapper, :env, :test
