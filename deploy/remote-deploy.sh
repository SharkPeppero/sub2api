#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: remote-deploy.sh --image IMAGE [options]

Install Docker when necessary and deploy Sub2API on an AMD64 or ARM64 Linux server.

Options:
  --image IMAGE       Release image to deploy (required)
  --deploy-dir DIR    Persistent deployment directory (default: /opt/sub2api)
  --compose-file FILE Compose file to install (default: beside this script)
  --env-file FILE     Optional complete .env file; replaces the managed .env
  --skip-install      Fail instead of installing Docker when it is unavailable
  --prepare-only      Only install/check Docker, then exit
EOF
}

image=""
deploy_dir="/opt/sub2api"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
compose_file="${script_dir}/docker-compose.yml"
env_file=""
skip_install=false
prepare_only=false

while (($#)); do
  case "$1" in
    --image) image=${2:?missing value for --image}; shift 2 ;;
    --deploy-dir) deploy_dir=${2:?missing value for --deploy-dir}; shift 2 ;;
    --compose-file) compose_file=${2:?missing value for --compose-file}; shift 2 ;;
    --env-file) env_file=${2:?missing value for --env-file}; shift 2 ;;
    --skip-install) skip_install=true; shift ;;
    --prepare-only) prepare_only=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$prepare_only" != true ]]; then
  [[ -n "$image" ]] || { echo "--image is required" >&2; exit 2; }
  [[ -f "$compose_file" ]] || { echo "Compose file not found: $compose_file" >&2; exit 2; }
fi
[[ "$deploy_dir" == /* && "$deploy_dir" != "/" ]] || {
  echo "--deploy-dir must be an absolute path other than /" >&2
  exit 2
}
[[ "$deploy_dir" =~ ^/[A-Za-z0-9._/-]+$ ]] || {
  echo "--deploy-dir contains unsupported characters" >&2
  exit 2
}
if [[ -n "$image" && ! "$image" =~ ^[a-zA-Z0-9._/:@-]+$ ]]; then
  echo "--image contains unsupported characters" >&2
  exit 2
fi

case "$(uname -m)" in
  x86_64|amd64) server_arch=amd64 ;;
  aarch64|arm64) server_arch=arm64 ;;
  *)
    echo "Unsupported server architecture: $(uname -m). Expected x86_64/amd64 or aarch64/arm64." >&2
    exit 1
    ;;
esac

if ((EUID == 0)); then
  sudo_cmd=()
elif command -v sudo >/dev/null 2>&1; then
  sudo_cmd=(sudo)
else
  echo "Run as root or install sudo first." >&2
  exit 1
fi

install_docker() {
  if command -v docker >/dev/null 2>&1 && "${sudo_cmd[@]}" docker compose version >/dev/null 2>&1; then
    return
  fi
  if [[ "$skip_install" == true ]]; then
    echo "Docker Engine with the Compose plugin is required." >&2
    exit 1
  fi
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required to install Docker." >&2
    exit 1
  }
  installer=$(mktemp)
  trap 'rm -f "${installer:-}"' EXIT
  curl --fail --show-error --silent --location https://get.docker.com --output "$installer"
  "${sudo_cmd[@]}" sh "$installer"
  rm -f "$installer"
  trap - EXIT
  "${sudo_cmd[@]}" systemctl enable --now docker 2>/dev/null || true
  "${sudo_cmd[@]}" docker compose version >/dev/null
}

random_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  else
    "${sudo_cmd[@]}" docker run --rm alpine:3.21 sh -c \
      "dd if=/dev/urandom bs=$1 count=1 2>/dev/null | od -An -tx1 | tr -d ' \\n'"
  fi
}

install_docker
if [[ "$prepare_only" == true ]]; then
  echo "Docker Engine and the Compose plugin are ready on ${server_arch}."
  exit 0
fi

"${sudo_cmd[@]}" install -d -m 0750 "$deploy_dir"
"${sudo_cmd[@]}" install -m 0644 "$compose_file" "$deploy_dir/docker-compose.yml"

if [[ -n "$env_file" ]]; then
  [[ -s "$env_file" ]] || { echo "Environment file is empty or missing: $env_file" >&2; exit 2; }
  "${sudo_cmd[@]}" install -m 0600 "$env_file" "$deploy_dir/.env"
elif ! "${sudo_cmd[@]}" test -f "$deploy_dir/.env"; then
  postgres_password=$(random_hex 32)
  jwt_secret=$(random_hex 32)
  totp_key=$(random_hex 32)
  generated_env=$(mktemp)
  trap 'rm -f "${generated_env:-}"' EXIT
  umask 077
  cat >"$generated_env" <<EOF
SUB2API_IMAGE=${image}
BIND_HOST=0.0.0.0
SERVER_PORT=8080
SERVER_MODE=release
TZ=Asia/Shanghai
POSTGRES_USER=sub2api
POSTGRES_PASSWORD=${postgres_password}
POSTGRES_DB=sub2api
JWT_SECRET=${jwt_secret}
TOTP_ENCRYPTION_KEY=${totp_key}
EOF
  "${sudo_cmd[@]}" install -m 0600 "$generated_env" "$deploy_dir/.env"
  rm -f "$generated_env"
  trap - EXIT
fi

# Always deploy the immutable image selected by the release workflow while
# preserving every other operator-managed value in .env.
if "${sudo_cmd[@]}" grep -q '^SUB2API_IMAGE=' "$deploy_dir/.env"; then
  "${sudo_cmd[@]}" sed -i "s|^SUB2API_IMAGE=.*$|SUB2API_IMAGE=${image}|" "$deploy_dir/.env"
else
  printf 'SUB2API_IMAGE=%s\n' "$image" | "${sudo_cmd[@]}" tee -a "$deploy_dir/.env" >/dev/null
fi

"${sudo_cmd[@]}" docker compose --project-directory "$deploy_dir" pull
"${sudo_cmd[@]}" docker compose --project-directory "$deploy_dir" up -d --remove-orphans
"${sudo_cmd[@]}" docker compose --project-directory "$deploy_dir" ps

echo "Sub2API ${image} is deployed for ${server_arch} from ${deploy_dir}."
