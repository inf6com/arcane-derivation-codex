#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE_DIR="${WWW_FTP_REMOTE_DIR:-inf6.com}"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    printf 'required environment variable is missing: %s\n' "$name" >&2
    exit 64
  fi
}

require_var WWW_FTP_HOST
require_var WWW_FTP_USER
require_var WWW_FTP_PASSWORD

if [[ ! "$WWW_FTP_HOST" =~ ^([A-Za-z0-9.-]+|\[[0-9A-Fa-f:]+\])(:[0-9]{1,5})?$ ]]; then
  printf 'WWW_FTP_HOST must be a DNS name or IP address, optionally followed by a port; do not include a URL scheme or path.\n' >&2
  exit 64
fi

if [[ ! "$REMOTE_DIR" =~ ^[A-Za-z0-9._~/\/-]+$ ]]; then
  printf 'WWW_FTP_REMOTE_DIR must be a path containing only letters, digits, slash, dot, underscore, hyphen, or tilde.\n' >&2
  exit 64
fi

cd "$ROOT"
python3 scripts/validate_www.py

find . \
  -path './.git' -prune -o \
  -path './.server-backup' -prune -o \
  -path './scripts' -prune -o \
  -type f \
  ! -name '._*' \
  ! -name '.DS_Store' \
  -print |
while IFS= read -r file; do
  rel="${file#./}"
  curl --fail --ftp-create-dirs \
    --user "$WWW_FTP_USER:$WWW_FTP_PASSWORD" \
    --upload-file "$file" \
    "ftp://$WWW_FTP_HOST/$REMOTE_DIR/$rel"
done

printf 'WWW deploy completed: ftp://%s/%s\n' "$WWW_FTP_HOST" "$REMOTE_DIR"
