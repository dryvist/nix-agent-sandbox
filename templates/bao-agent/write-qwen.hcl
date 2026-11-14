auto_auth {
  method "approle" {
    exit_on_err = false
    config = {
      role_id_file_path                    = "/dev/shm/agent-openbao/role-id"
      secret_id_file_path                  = "/dev/shm/agent-openbao/wrapped-secret-id"
      secret_id_response_wrapping_path     = "auth/approle/role/sandbox-agent-write/secret-id"
    }
  }
}

template_config {
  exit_on_retry_failure         = true
  static_secret_render_interval = "24h"
}

env_template "AGENT_ROUTER_KEY" {
  source                = "/etc/openbao-agent/templates/router-key.ctmpl"
  error_on_missing_key  = true
}

env_template "QWEN_MCP_CONFIG" {
  source                = "/etc/openbao-agent/templates/qwen-mcp-public.ctmpl"
  error_on_missing_key  = true
}

exec {
  command                   = ["@AGENT_ENTRYPOINT@"]
  restart_on_secret_changes = "never"
}
