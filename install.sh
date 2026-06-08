#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/opt/host-metrics"
ENV_FILE="$APP_DIR/.env"

SYSTEMD_DIR="/etc/systemd/system"
SERVICE_FILE="$APP_DIR/basilvision-push-metrics.service"
TIMER_FILE="$APP_DIR/basilvision-push-metrics.timer"
SERVICE_LINK="$SYSTEMD_DIR/basilvision-push-metrics.service"
TIMER_LINK="$SYSTEMD_DIR/basilvision-push-metrics.timer"
REPO_URL="https://github.com/maximilian-franz/basilvision-host-metrics"
REPO_BRANCH="main"

UNINSTALL_MODE=0
FORCE_UNINSTALL=0

EXISTING_API_URL=""
EXISTING_API_KEY=""
EXISTING_NAME=""
EXISTING_DEVICE_UUID=""
EXISTING_ENV_FOUND=0
KEEP_EXISTING_CONFIG=0

DEFAULT_NAME="Basil Vision Host Metrics"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "This installer must run as root."
    echo "Run with: curl -fsSL <INSTALLER_URL> | sudo bash"
    exit 1
  fi
}

require_tty() {
  if [[ ! -r /dev/tty ]]; then
    echo "Interactive mode requires a TTY (/dev/tty is not available)."
    exit 1
  fi
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --uninstall)
        UNINSTALL_MODE=1
        shift
        ;;
      --yes)
        FORCE_UNINSTALL=1
        shift
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  install.sh                Install host-metrics
  install.sh --uninstall    Uninstall host-metrics
  install.sh --uninstall --yes
                            Uninstall without confirmation prompt
EOF
        exit 0
        ;;
      *)
        echo "Unknown argument: $1"
        echo "Run with --help for usage."
        exit 1
        ;;
    esac
  done
}

prompt_input() {
  local prompt="$1"
  local value
  read -r -p "$prompt" value </dev/tty
  printf '%s' "$value"
}

prompt_secret() {
  local prompt="$1"
  local value
  read -r -s -p "$prompt" value </dev/tty
  echo >/dev/tty
  printf '%s' "$value"
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

read_env_value() {
  local key="$1"
  local file="$2"
  grep -E "^${key}=" "$file" | head -n 1 | cut -d'=' -f2-
}

prompt_default_yes() {
  local prompt="$1"
  local answer
  answer="$(prompt_input "$prompt [Y/n]: ")"
  [[ -z "$answer" || "$answer" =~ ^[Yy]$ ]]
}

generate_device_uuid() {
  openssl rand -base64 9
}

detect_existing_config() {
  EXISTING_API_URL=""
  EXISTING_API_KEY=""
  EXISTING_NAME=""
  EXISTING_DEVICE_UUID=""
  EXISTING_ENV_FOUND=0
  KEEP_EXISTING_CONFIG=0

  if [[ -f "$ENV_FILE" ]]; then
    EXISTING_ENV_FOUND=1
    EXISTING_API_URL="$(read_env_value API_URL "$ENV_FILE")"
    EXISTING_API_KEY="$(read_env_value API_KEY "$ENV_FILE")"
    EXISTING_NAME="$(read_env_value NAME "$ENV_FILE")"
    EXISTING_DEVICE_UUID="$(read_env_value DEVICE_UUID "$ENV_FILE")"
  fi
}

install_packages() {
  echo "[1/6] Installing required packages..."

  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y git curl ca-certificates openssl
    return
  fi

  echo "Unsupported package manager. Please install git, curl, and openssl manually."
  exit 1
}

fetch_repository() {
  echo "[2/6] Fetching repository into $APP_DIR..."

  if [[ -d "$APP_DIR/.git" ]]; then
    git -C "$APP_DIR" fetch --depth 1 origin "$REPO_BRANCH"
    git -C "$APP_DIR" checkout -f "origin/$REPO_BRANCH"
  else
    rm -rf "$APP_DIR"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$APP_DIR"
  fi

  local required=(
    "$APP_DIR/push_metrics.sh"
    "$APP_DIR/basilvision-push-metrics.service"
    "$APP_DIR/basilvision-push-metrics.timer"
  )

  local path
  for path in "${required[@]}"; do
    if [[ ! -f "$path" ]]; then
      echo "Missing required file in repository: $path"
      exit 1
    fi
  done

  chmod 755 "$APP_DIR/push_metrics.sh"
  chown root:root "$APP_DIR/push_metrics.sh"
}

prompt_credentials() {
  echo "[3/6] API configuration"

  if [[ "$EXISTING_ENV_FOUND" -eq 1 && -n "$EXISTING_API_URL" && -n "$EXISTING_API_KEY" ]]; then
    if prompt_default_yes "Existing configuration found for ${EXISTING_API_URL}. Keep it"; then
      API_URL="$EXISTING_API_URL"
      API_KEY="$EXISTING_API_KEY"
      NAME="$EXISTING_NAME"
      DEVICE_UUID="$EXISTING_DEVICE_UUID"
      KEEP_EXISTING_CONFIG=1
      return
    fi
  fi

  API_URL="$(prompt_input "Enter API URL: ")"
  while [[ -z "${API_URL}" ]]; do
    API_URL="$(prompt_input "API URL cannot be empty. Enter API URL: ")"
  done

  API_KEY="$(prompt_secret "Enter API key: ")"
  while [[ -z "${API_KEY}" ]]; do
    API_KEY="$(prompt_secret "API key cannot be empty. Enter API key: ")"
  done

  local default_name="${EXISTING_NAME:-$DEFAULT_NAME}"
  NAME="$(prompt_input "Enter device name [${default_name}]: ")"
  if [[ -z "$NAME" ]]; then
    NAME="$default_name"
  fi

  local default_uuid="${EXISTING_DEVICE_UUID:-$(generate_device_uuid)}"
  DEVICE_UUID="$(prompt_input "Enter device UUID [${default_uuid}]: ")"
  if [[ -z "$DEVICE_UUID" ]]; then
    DEVICE_UUID="$default_uuid"
  fi

  KEEP_EXISTING_CONFIG=0
}

install_env_file() {
  echo "[4/6] Writing environment file..."

  cat >"$ENV_FILE" <<EOF
API_URL="${API_URL}"
API_KEY="${API_KEY}"
NAME="${NAME}"
DEVICE_UUID="${DEVICE_UUID}"
EOF

  chmod 640 "$ENV_FILE"
  chown root:root "$ENV_FILE"
}

install_systemd_units() {
  echo "[5/6] Installing systemd service and timer..."

  if [[ ! -f "$SERVICE_FILE" || ! -f "$TIMER_FILE" ]]; then
    echo "Service or timer file missing in repository."
    exit 1
  fi

  chmod 644 "$SERVICE_FILE" "$TIMER_FILE"
  chown root:root "$SERVICE_FILE" "$TIMER_FILE"

  ln -sfn "$SERVICE_FILE" "$SERVICE_LINK"
  ln -sfn "$TIMER_FILE" "$TIMER_LINK"

  systemctl daemon-reload
}

enable_and_start_services() {
  echo "[6/6] Enabling and starting services..."

  systemctl enable basilvision-push-metrics.service
  systemctl enable --now basilvision-push-metrics.timer
}

show_summary() {
  echo
  echo "Installation complete"
  echo
  echo "Repository: $REPO_URL (branch: $REPO_BRANCH)"
  echo "Installed path: $APP_DIR"
  echo "Environment file: $ENV_FILE"

  if [[ "$KEEP_EXISTING_CONFIG" -eq 1 ]]; then
    echo "API config: kept existing (${API_URL})"
  else
    echo "API URL: ${API_URL}"
    echo "Device name: ${NAME}"
    echo "Device UUID: ${DEVICE_UUID}"
  fi

  echo
  echo "Credentials were written to:"
  echo "  - $ENV_FILE"
  echo
  echo "Useful commands:"
  echo "  systemctl status basilvision-push-metrics.timer"
  echo "  systemctl start basilvision-push-metrics.service"
  echo "  journalctl -u basilvision-push-metrics.service -n 200 --no-pager"
}

confirm_uninstall() {
  if [[ "$FORCE_UNINSTALL" -eq 1 ]]; then
    return
  fi

  require_tty

  echo
  echo "This will remove:"
  echo "  - $APP_DIR"
  echo "  - $SERVICE_LINK and $TIMER_LINK"
  echo "  - It will also stop/disable basilvision-push-metrics timer/service"
  echo

  local answer
  answer="$(prompt_input "Continue uninstall? [y/N]: ")"
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Uninstall cancelled."
    exit 0
  fi
}

uninstall_everything() {
  echo "[UNINSTALL] Stopping and disabling services..."

  systemctl disable --now basilvision-push-metrics.timer >/dev/null 2>&1 || true
  systemctl disable --now basilvision-push-metrics.service >/dev/null 2>&1 || true

  echo "[UNINSTALL] Removing systemd links and reloading daemon..."

  rm -f "$SERVICE_LINK" "$TIMER_LINK"
  systemctl daemon-reload

  echo "[UNINSTALL] Removing installed application files..."
  rm -rf "$APP_DIR"

  echo
  echo "Uninstall complete."
}

main() {
  parse_args "$@"

  require_root

  if [[ "$UNINSTALL_MODE" -eq 1 ]]; then
    confirm_uninstall
    uninstall_everything
    return
  fi

  require_tty
  install_packages
  detect_existing_config
  fetch_repository
  prompt_credentials
  install_env_file
  install_systemd_units
  enable_and_start_services
  show_summary
}

main "$@"
