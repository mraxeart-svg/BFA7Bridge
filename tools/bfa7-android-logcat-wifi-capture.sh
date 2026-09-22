#!/usr/bin/env bash
set -euo pipefail

OUT="${1:-/tmp/bfa7_xiaomi_wifi_credentials.txt}"
ADB="${ADB:-adb}"

adb_cmd=("$ADB")
if [[ -n "${ANDROID_SERIAL:-}" ]]; then
  adb_cmd+=("-s" "$ANDROID_SERIAL")
fi

if ! command -v "$ADB" >/dev/null 2>&1; then
  echo "adb not found. Install Android platform-tools or set ADB=/path/to/adb." >&2
  exit 127
fi

cat <<EOF
BFA7 Xiaomi Glasses Wi-Fi credential capture

1. Connect an Android phone with Xiaomi Glasses (com.xiaomi.superhexa) installed.
2. Enable USB debugging and authorize this computer.
3. Keep this script running.
4. In Xiaomi Glasses, start photo/import sync.
5. When credentials appear below, do not install random APKs; use the values only for your own paired glasses.

Writing latest credentials to: $OUT
EOF

ssid=""
password=""
gateway=""

"${adb_cmd[@]}" logcat -v time | while IFS= read -r line; do
  case "$line" in
    *O95FileSpace*|*"wiFi AP"*|*"wifi AP"*|*gateway:*|*password:*|*ssid:*)
      printf '%s\n' "$line"
      ;;
    *)
      continue
      ;;
  esac

  if [[ "$line" =~ ssid:[[:space:]]*\"([^\"]+)\" ]]; then
    ssid="${BASH_REMATCH[1]}"
  fi
  if [[ "$line" =~ password:[[:space:]]*\"([^\"]+)\" ]]; then
    password="${BASH_REMATCH[1]}"
  fi
  if [[ "$line" =~ gateway:[[:space:]]*\"?([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\"? ]]; then
    gateway="${BASH_REMATCH[1]}"
  fi

  if [[ -n "$ssid" && -n "$password" && -n "$gateway" ]]; then
    {
      printf 'captured_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf 'ssid=%s\n' "$ssid"
      printf 'password=%s\n' "$password"
      printf 'gateway=%s\n' "$gateway"
      printf 'api_base=http://%s:8080/v1/\n' "$gateway"
    } > "$OUT"

    printf '\nCaptured BFA7 Wi-Fi credentials:\n'
    cat "$OUT"
    printf '\n'
  fi
done
