# wireguard-server

Scripts and tools for building and maintaining WireGuard networks from the command line.

## Highlights

- Idempotent install and client-management workflows.
- Single omnibus `wg-client` command (`add`, `remove`, `list`, `show`, `update`, `status`).
- Server data stored in a predictable root-owned location: `/etc/wireguard`.
- Safer error handling with strict shell mode and runtime checks.

## Server Installation

Run server install from this repository:

```bash
bash install-server.sh
```

By default, the script does **not** run `apt update`/`dist-upgrade`; use `-u` when needed.

### `install-server.sh` flags

| Flag | Description |
| :--- | :--- |
| `-d` | Use dev branch metadata. |
| `-f` | Force run as root. |
| `-h` / `--help` | Show help. |
| `-i IP_RANGE` | Set server WireGuard IP (for `wg0`, default `10.100.200.1`). |
| `-m` | Enable full-tunnel mode (route all client traffic). |
| `-n KEY_NAME` | Set server key file name prefix. |
| `-o` | Overwrite existing server keys/config. |
| `-p LISTEN_PORT` | Set WireGuard listen port (default `51820`). |
| `-u` | Run `apt update` and `dist-upgrade`. |
| `-v` | Verbose output. |

## Client Management

Main command:

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
| `-v` | Verbose output. |
| `-D` | Remove client files when running `remove`. |

## Server Configuration File

`install-server.sh` writes tool metadata to:

`/etc/wireguard/wg-server.conf`

Example values:

```bash
VERSION="2.13.0"
ADAPTER="eth0"
MA_MODE="false"
CLIENT_ALLOWED_IPS="10.100.200.0/24"
SERVER_IP="10.100.200.1"
SERVER_PORT="51820"
SERVER_PRIVATE_FILE="server_key.pri"
SERVER_PUBLIC_FILE="server_key.pub"
```

`CLIENT_ALLOWED_IPS` is consumed by `wg-client` when generating client configs (unless `MA_MODE=true`, where `0.0.0.0/0` is used).

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

Server layout:

- `/etc/wireguard/wg-server.conf` - runtime settings for tools
- `/etc/wireguard/wg0.conf` - active server WireGuard config
- `/etc/wireguard/server/wg0.conf` - managed server template output
- `/etc/wireguard/server/server_key.pri` / `/etc/wireguard/server/server_key.pub` - server keypair
- `/etc/wireguard/clients/<peer_name>/` - per-client files (`wg0.conf`, keys, QR)
- `/etc/wireguard/clients/<peer_name>.zip` and `.tar.gz` - exported client bundles
- `/etc/wireguard/peer_list.txt` - tracked peers (`ip,name,pubkey`)
- `/etc/wireguard/last_ip.txt` - last assigned client IP
- `/etc/wireguard/config/` - config templates

Installed tool files:

- `/usr/local/bin/wg-client`
- `/usr/local/share/wireguard/lib/common.sh`
- `/usr/local/share/wireguard/install-client.sh`
