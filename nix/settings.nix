{ pluginPath }:

{
  "$schema" = "https://www.getbifrost.ai/schema";
  providers."codex-subscription" = {
    network_config.base_url = "https://chatgpt.com/backend-api/codex";
    openai_config.disable_store = true;
    custom_provider_config = {
      base_provider_type = "openai";
      is_key_less = true;
      allowed_requests.responses_stream = true;
      request_path_overrides.responses_stream = "/responses";
    };
  };
  plugins = [
    {
      name = "codex-subscription-oauth";
      enabled = true;
      path = pluginPath;
      config = { };
    }
  ];
}
