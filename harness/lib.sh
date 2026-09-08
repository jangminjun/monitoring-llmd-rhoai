HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log()  { printf '\033[1;34m[llmd-harness]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[llmd-harness:error]\033[0m %s\n' "$*" >&2; exit 1; }

ssh_bastion() {
  ssh -o StrictHostKeyChecking=accept-new -o ServerAliveInterval=30 -o ServerAliveCountMax=6 \
    -i "$SSH_KEY_PATH" "ec2-user@${BASTION_IP}" "$@"
}

scp_to_bastion() {
  scp -o StrictHostKeyChecking=accept-new -i "$SSH_KEY_PATH" "$1" "ec2-user@${BASTION_IP}:$2"
}
