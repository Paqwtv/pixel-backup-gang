#!/bin/sh

set -eu

################################################################################
# Description: mount/unmount the configured external SSD from one phone command.
# Usage: ./ssd.sh mount|unmount|status
################################################################################

SELF_PATH=$0
COMMAND=${1:-}

if [ -z "$COMMAND" ]; then
  echo "Usage: $0 mount|unmount|status" >&2
  exit 1
fi

case "$COMMAND" in
  mount|unmount|status) ;;
  *)
    echo "Usage: $0 mount|unmount|status" >&2
    exit 1
    ;;
esac

quote_shell_arg() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

resolve_self_path() {
  case "$SELF_PATH" in
    */*) printf '%s\n' "$SELF_PATH" ;;
    *)
      command -v "$SELF_PATH" 2>/dev/null || {
        echo "Unable to resolve script path: $SELF_PATH" >&2
        exit 1
      }
      ;;
  esac
}

select_shell() {
  if [ -n "${PBG_SHELL:-}" ]; then
    printf '%s\n' "$PBG_SHELL"
  elif [ -x /system/bin/sh ]; then
    printf '%s\n' /system/bin/sh
  elif [ -x /bin/sh ]; then
    printf '%s\n' /bin/sh
  else
    printf '%s\n' sh
  fi
}

resolved_self=$(resolve_self_path)
script_dir=$(unset CDPATH; cd "$(dirname "$resolved_self")" && pwd)
script_name=${resolved_self##*/}
SELF_ABS="$script_dir/$script_name"
PBG_RUN_SHELL=$(select_shell)

CONFIG_DIR="${PBG_CONFIG_DIR:-$script_dir/config}"
UUID_FILE="${PBG_UUID_FILE:-$CONFIG_DIR/drive.uuid}"
LOCK_DIR="${PBG_LOCK_DIR:-$CONFIG_DIR/ssd.lock}"
DRIVE_MOUNT_DIR="${PBG_DRIVE_MOUNT_DIR:-/mnt/my_drive}"
BINDING_DIR="${PBG_BINDING_DIR:-/mnt/runtime/write/emulated/0/the_binding}"
PROC_MOUNTS="${PBG_PROC_MOUNTS:-/proc/mounts}"
NSENTER_COMMAND="${PBG_NSENTER:-nsenter}"

if [ -n "${PBG_HELPER_DIR:-}" ]; then
  helper_dir=$PBG_HELPER_DIR
elif [ -f "$script_dir/scripts/find_device.sh" ]; then
  helper_dir="$script_dir/scripts"
else
  helper_dir="$script_dir"
fi

if [ "${PBG_ASSUME_ROOT:-0}" != "1" ] && [ "$(id -u)" != "0" ]; then
  exec su -c "PBG_SHELL=$(quote_shell_arg "$PBG_RUN_SHELL") PBG_CONFIG_DIR=$(quote_shell_arg "$CONFIG_DIR") PBG_UUID_FILE=$(quote_shell_arg "$UUID_FILE") PBG_HELPER_DIR=$(quote_shell_arg "$helper_dir") PBG_LOCK_DIR=$(quote_shell_arg "$LOCK_DIR") PBG_DRIVE_MOUNT_DIR=$(quote_shell_arg "$DRIVE_MOUNT_DIR") PBG_BINDING_DIR=$(quote_shell_arg "$BINDING_DIR") PBG_PROC_MOUNTS=$(quote_shell_arg "$PROC_MOUNTS") PBG_NSENTER=$(quote_shell_arg "$NSENTER_COMMAND") $(quote_shell_arg "$PBG_RUN_SHELL") $(quote_shell_arg "$SELF_ABS") $(quote_shell_arg "$COMMAND")"
fi

find_device="$helper_dir/find_device.sh"
mount_ext4="$helper_dir/mount_ext4.sh"
unmount_drive="$helper_dir/unmount.sh"

require_file() {
  if [ ! -f "$1" ]; then
    echo "Missing required file: $1" >&2
    exit 1
  fi
}

read_configured_uuid() {
  require_file "$UUID_FILE"

  uuid_lines=$(sed '/^[[:space:]]*$/d' "$UUID_FILE")
  uuid_line_count=$(printf '%s\n' "$uuid_lines" | sed '/^$/d' | wc -l | tr -d ' ')

  if [ "$uuid_line_count" -eq 0 ]; then
    echo "UUID file is empty: $UUID_FILE" >&2
    exit 1
  fi

  if [ "$uuid_line_count" -ne 1 ]; then
    echo "UUID file must contain exactly one UUID: $UUID_FILE" >&2
    exit 1
  fi

  uuid=$uuid_lines
  case "$uuid" in
    *[!0-9A-Fa-f-]*)
      echo "UUID file contains invalid characters: $UUID_FILE" >&2
      exit 1
      ;;
  esac

  printf '%s\n' "$uuid"
}

acquire_lock() {
  lock_parent=${LOCK_DIR%/*}
  if [ "$lock_parent" != "$LOCK_DIR" ] && [ ! -d "$lock_parent" ]; then
    echo "Lock parent directory is missing: $lock_parent" >&2
    exit 1
  fi

  if mkdir "$LOCK_DIR" 2>/dev/null; then
    trap 'release_lock' EXIT HUP INT TERM
    return
  fi

  if [ -d "$LOCK_DIR" ]; then
    echo "Another SSD operation is already running: $LOCK_DIR" >&2
  else
    echo "Unable to acquire SSD operation lock: $LOCK_DIR" >&2
  fi

  exit 1
}

release_lock() {
  if [ -d "$LOCK_DIR" ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

mounted_source_for() {
  mount_point=$1

  if [ ! -f "$PROC_MOUNTS" ]; then
    return 1
  fi

  awk -v target="$mount_point" '$2 == target {print $1}' "$PROC_MOUNTS" | sed -n '1p'
}

canonical_path() {
  path=$1

  if command -v readlink >/dev/null 2>&1; then
    resolved=$(readlink -f "$path" 2>/dev/null || true)
    if [ -n "$resolved" ]; then
      printf '%s\n' "$resolved"
      return
    fi
  fi

  printf '%s\n' "$path"
}

same_device() {
  [ "$(canonical_path "$1")" = "$(canonical_path "$2")" ]
}

is_mounted_at() {
  [ -n "$(mounted_source_for "$1")" ]
}

ensure_mountpoint_available_for() {
  block_device=$1
  mounted_source=$(mounted_source_for "$DRIVE_MOUNT_DIR" || true)
  binding_source=$(mounted_source_for "$BINDING_DIR" || true)
  expected_binding_source="$DRIVE_MOUNT_DIR/the_binding"

  if [ -z "$mounted_source" ]; then
    if [ -n "$binding_source" ]; then
      echo "Binding mount point is already busy: $BINDING_DIR ($binding_source)" >&2
      exit 1
    fi

    return
  fi

  if same_device "$mounted_source" "$block_device"; then
    if [ -n "$binding_source" ] && ! same_device "$binding_source" "$expected_binding_source"; then
      echo "Binding mount point is busy with another source: $BINDING_DIR ($binding_source)" >&2
      exit 1
    fi

    echo "SSD already mounted at $DRIVE_MOUNT_DIR"
    exit 0
  fi

  echo "Mount point busy with another device: $DRIVE_MOUNT_DIR ($mounted_source)" >&2
  exit 1
}

require_helper() {
  if [ ! -f "$1" ]; then
    echo "Missing helper: $1" >&2
    exit 1
  fi
}

run_in_global_namespace() {
  if [ "${PBG_ASSUME_GLOBAL_NAMESPACE:-0}" = "1" ]; then
    return
  fi

  if [ "${PBG_FORCE_NAMESPACE_SWITCH:-0}" = "1" ] || [ "$(readlink /proc/self/ns/mnt)" != "$(readlink /proc/1/ns/mnt)" ]; then
    if ! command -v "$NSENTER_COMMAND" >/dev/null 2>&1; then
      echo "nsenter is required to enter the global mount namespace" >&2
      exit 1
    fi

    exec "$NSENTER_COMMAND" -t 1 -m -- "$PBG_RUN_SHELL" "$SELF_ABS" "$COMMAND"
  fi
}

resolve_block_devices() {
  read_configured_uuid >/dev/null
  block_devices=$("$PBG_RUN_SHELL" -e "$find_device" "$UUID_FILE" || true)
  printf '%s\n' "$block_devices" | sed '/^$/d'
}

find_configured_block_device() {
  block_devices=$(resolve_block_devices)
  block_device_count=$(printf '%s\n' "$block_devices" | sed '/^$/d' | wc -l | tr -d ' ')

  if [ "$block_device_count" -eq 0 ]; then
    echo "SSD block device not found for UUID in $UUID_FILE" >&2
    exit 1
  fi

  if [ "$block_device_count" -ne 1 ]; then
    echo "Expected one SSD block device for UUID in $UUID_FILE, found $block_device_count:" >&2
    printf '%s\n' "$block_devices" >&2
    exit 1
  fi

  printf '%s\n' "$block_devices"
}

status_command() {
  read_configured_uuid >/dev/null
  require_helper "$find_device"
  run_in_global_namespace

  block_devices=$(resolve_block_devices)
  block_device_count=$(printf '%s\n' "$block_devices" | sed '/^$/d' | wc -l | tr -d ' ')

  if [ "$block_device_count" -eq 1 ]; then
    block_device=$block_devices
    echo "configured SSD found at $block_device"
  elif [ "$block_device_count" -eq 0 ]; then
    echo "configured SSD not found"
    return 1
  else
    echo "configured SSD matched multiple devices:" >&2
    printf '%s\n' "$block_devices" >&2
    return 1
  fi

  drive_source=$(mounted_source_for "$DRIVE_MOUNT_DIR" || true)
  binding_source=$(mounted_source_for "$BINDING_DIR" || true)

  if [ -n "$drive_source" ]; then
    echo "drive mount: $DRIVE_MOUNT_DIR <- $drive_source"
  else
    echo "drive mount: not mounted"
  fi

  if [ -n "$binding_source" ]; then
    echo "binding mount: $BINDING_DIR <- $binding_source"
  else
    echo "binding mount: not mounted"
  fi
}

case "$COMMAND" in
  mount)
    read_configured_uuid >/dev/null
    require_helper "$find_device"
    require_helper "$mount_ext4"
    run_in_global_namespace
    acquire_lock

    block_device=$(find_configured_block_device)
    ensure_mountpoint_available_for "$block_device"
    "$PBG_RUN_SHELL" -ex "$mount_ext4" "$block_device"
    ;;

  unmount)
    require_helper "$unmount_drive"
    run_in_global_namespace
    acquire_lock

    if ! is_mounted_at "$DRIVE_MOUNT_DIR" && ! is_mounted_at "$BINDING_DIR"; then
      echo "SSD is not mounted"
      exit 0
    fi

    drive_source=$(mounted_source_for "$DRIVE_MOUNT_DIR" || true)
    if [ -n "$drive_source" ]; then
      block_device=$(find_configured_block_device)
      if ! same_device "$drive_source" "$block_device"; then
        echo "Refusing to unmount another device at $DRIVE_MOUNT_DIR ($drive_source)" >&2
        exit 1
      fi
    else
      echo "Refusing to unmount binding without drive mount: $BINDING_DIR" >&2
      exit 1
    fi

    "$PBG_RUN_SHELL" -x "$unmount_drive"
    ;;

  status)
    status_command
    ;;
esac
