import json
import os
from mitmproxy import ctx
from mitmproxy.proxy import layer, layers

# Global dictionary initialized empty, populated dynamically during load
OVERRIDES = {}


def generate_pac_file(domains):
    """Generates a JavaScript PAC file content dynamically based on domains list."""
    pac_dir = "./pac"
    pac_path = os.path.join(pac_dir, "proxy.pac")

    # Ensure the target directory exists
    os.makedirs(pac_dir, exist_ok=True)

    # Build conditional rules for each domain in the json config
    conditions = []
    for domain in domains:
        conditions.append(f'shExpMatch(host, "*.{domain}") || host === "{domain}"')

    # Combine conditions using JavaScript OR operators
    js_condition = " ||\n      ".join(conditions)

    # Fallback to direct connection if domains list is empty
    if not conditions:
        js_condition = "false"

    pac_content = f"""function FindProxyForURL(url, host) {{
  // Route only specific domains from config.json through your proxy
  if ({js_condition}) {{
    return "PROXY 127.0.0.1:8080";
  }}

  // Send all other traffic directly without proxy
  return "DIRECT";
}}
"""

    with open(pac_path, "w", encoding="utf-8") as f:
        f.write(pac_content)
    print(f"[*] Dynamic PAC file successfully written to: {pac_path}")


def load_config():
    """Reads configuration payload from JSON storage."""
    global OVERRIDES
    config_path = "config.json"

    if not os.path.exists(config_path):
        print(f"[-] Critical: {config_path} not found! Initializing empty rules.")
        return

    try:
        with open(config_path, "r", encoding="utf-8") as f:
            OVERRIDES = json.load(f)
        print(
            f"[*] Successfully loaded {len(OVERRIDES)} domain routing profiles from config."
        )
    except Exception as e:
        print(f"[-] Error loading configuration profile data: {e}")


def load(loader):
    """Mitmproxy lifecycle hook triggered immediately when script loads."""
    load_config()
    generate_pac_file(OVERRIDES.keys())


def running():
    # Force connection strategy to lazy so mitmproxy evaluates next_layer
    # hooks accurately prior to making initial upstream connections
    ctx.options.connection_strategy = "lazy"


def next_layer(nextlayer: layer.NextLayer) -> None:
    # Safely look up client SNI context details
    sni = nextlayer.context.client.sni

    if not sni:
        return

    matched_domain = OVERRIDES.get(sni)
    if matched_domain:
        print(
            f"[!] Intercepted SNI for {sni}. Rerouting raw TCP to {matched_domain['ip']}:{matched_domain['port']}"
        )

        # Override the destination endpoint map layout
        nextlayer.context.server.address = (
            matched_domain["ip"],
            matched_domain["port"],
        )

        # Override layer processing logic to enforce pure, blind TCP pass-through tunnel
        nextlayer.layer = layers.TCPLayer(nextlayer.context)
