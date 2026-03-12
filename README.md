# wireguard-server

Scripts and tools for building and maintaining WireGuard networks from the command line.

## Highlights

- Idempotent install and client-management workflows.
- Unified `wg-client` command for add/list/remove/show/update/status.
- Backward-compatible wrappers: `add-client.sh` and `remove-client.sh`.
- Safer error handling with strict shell mode and better runtime checks.

## Server Installation

Run server install from this repository:

```bash
bash install-server.sh
```

By default, the script does **not** run `apt update`/`dist-upgrade`; use `-u` when needed.

### `install-server.sh` flags

| Flag | Description |
| :--- | :--- |
| `-c CONFIG_DIR` | Set configuration directory. |
| `-d` | Use dev branch metadata. |
| `-f` | Force run as root. |
| `-h` / `--help` | Show help. |
| `-i IP_RANGE` | Set server WireGuard IP (for `wg0`, default `10.100.200.1`). |
| `-m` | Enable full-tunnel mode (route all client traffic). |
| `-n KEY_NAME` | Set server key file name prefix. |
| `-o` | Overwrite existing server keys/config. |
| `-p LISTEN_PORT` | Set WireGuard listen port (default `51820`). |
| `-t TOOL_DIR` | Set tool installation directory (default `~/wireguard`). |
| `-u` | Run `apt update` and `dist-upgrade`. |
| `-v` | Verbose output. |

## Client Management

Main command:

```bash
~/wireguard/wg-client.sh <command> [options]
```

If installed globally by `install-server.sh`, you can also use:

```bash
wg-client <command> [options]
```

### `wg-client` commands

| Command | Description |
| :--- | :--- |
| `add <peer_name>` | Create/update client files and register peer on server. |
| `list` | List known peers from `peer_list.txt`. |
| `remove <name_or_pubkey>` | Remove peer from live WG state and persisted config. |
| `show [peer_name]` | Show a specific client config or `wg show` output when omitted. |
| `update <peer_name>` | Recreate keys/config for an existing peer, preserving its IP by default. |
| `status` | Show live WireGuard interface status. |
| `help` | Display usage. |

### `wg-client` options

| Flag | Description |
| :--- | :--- |
| `-f` | Force run as root. |
| `-h` | Show help. |
| `-i IP_ADDRESS` | Override peer IP (for add/update). |
| `-o` | Overwrite existing peer/client entry. |
| `-p SERVER_PORT` | Override server listen port in generated client config. |
| `-q` | Print client config as QR code in terminal. |
| `-s SERVER_IP` | Override server endpoint IP in generated client config. |
| `-t TOOL_DIR` | Override tool directory. |
| `-v` | Verbose output. |
| `-D` | Remove local client files when running `remove`. |

## Compatibility Wrappers

The following wrappers are kept for backward compatibility:

- `tools/add-client.sh` -> forwards to `wg-client add`
- `tools/remove-client.sh` -> forwards to `wg-client remove`

## Client-Side Installation

Client bundles include `install-client.sh`. Run it in the client bundle directory:

```bash
bash install-client.sh
```

### `install-client.sh` flags

| Flag | Description |
| :--- | :--- |
| `-c CONF_FILE` | Path to config file (default `./wg0.conf`). |
| `-f` | Force run as root. |
| `-h` | Show help. |
| `-u` | Run `apt update` before package install. |
| `-v` | Verbose output. |

## Files and Layout

Default tool layout under `~/wireguard`:

- `server.conf` - runtime settings
- `server/wg0.conf` - managed server config
- `server/server_key.pri` / `server/server_key.pub` - server keypair
- `clients/<peer_name>/` - per-client files (`wg0.conf`, keys, QR)
- `clients/<peer_name>.zip` and `.tar.gz` - exported client bundles
- `peer_list.txt` - tracked peers (`ip,name,pubkey`)
- `last_ip.txt` - last assigned client IP
