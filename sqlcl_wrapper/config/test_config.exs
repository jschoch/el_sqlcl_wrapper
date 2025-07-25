import Config

# Test configuration for SQLcl wrapper
config :sqlcl_wrapper,
  # Default connection for tests - can be overridden via environment variables
  default_connection: System.get_env("SQLCL_TEST_CONNECTION") || "theconn",

  # SQLcl executable path
  sqlcl_executable: System.get_env("SQLCL_PATH") || "/mnt/c/Files/downloads/sqlcl-25.2.0.184.2054/sqlcl/bin/sql.exe",

  # Test timeout settings
  test_timeout: 30_000,
  connection_timeout: 10_000,
  sqlcl_startup_timeout: 15_000,

  # Test database configuration
  test_connection_config: %{
    primary: System.get_env("SQLCL_TEST_CONNECTION") || "theconn",
    secondary: System.get_env("SQLCL_TEST_CONNECTION_2") || "test123",
    username: System.get_env("SQLCL_TEST_USERNAME") || "testuser",
    schema: System.get_env("SQLCL_TEST_SCHEMA") || "TESTSCHEMA"
  },

  # Test data and queries
  test_queries: %{
    simple_select: "SELECT /* LLM in use is claude-sonnet-4 */ 1 FROM DUAL",
    dual_query: "SELECT /* LLM in use is claude-sonnet-4 */ 'Hello SQLcl' AS message FROM DUAL",
    table_count: "SELECT /* LLM in use is claude-sonnet-4 */ COUNT(*) FROM USER_TABLES",
    current_user: "SELECT /* LLM in use is claude-sonnet-4 */ USER FROM DUAL",
    list_tables: "SELECT /* LLM in use is claude-sonnet-4 */ table_name FROM user_tables ORDER BY table_name",
    describe_table: "DESCRIBE %{table_name}",
    version_check: "SELECT /* LLM in use is claude-sonnet-4 */ * FROM V$VERSION WHERE ROWNUM = 1"
  },

  # Expected test tables (these should exist in the test database)
  expected_tables: ["USERS", "POSTS", "FOLLOWERS"],

  # Test data validation
  test_data_validation: %{
    users_table: %{
      columns: ["ID", "USERNAME", "EMAIL", "PASSWORD_HASH", "REGISTRATION_DATE"],
      sample_data: ["john_doe", "jane_smith", "alice_jones"]
    }
  },

  # MCP server configuration for testing
  mcp_server: [
    port: 4000,
    host: "localhost",
    protocol_version: "2025-06-18"
  ],

  # Test environment settings
  test_environment: %{
    cleanup_on_exit: true,
    parallel_tests: false,
    log_level: :info,
    capture_sqlcl_output: true
  }
