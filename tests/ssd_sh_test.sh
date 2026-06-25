#!/bin/sh

set -eu

repo_root=$(unset CDPATH; cd "$(dirname "$0")/.." && pwd)
tmp_root=$(mktemp -d "${TMPDIR:-/tmp}/pbg-ssd-test.XXXXXX")
trap 'rm -rf "$tmp_root"' EXIT HUP INT TERM

pass_count=0

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_eq() {
  expected=$1
  actual=$2
  message=$3

  if [ "$expected" != "$actual" ]; then
    printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  needle=$1
  file=$2
  message=$3

  if ! grep -F -- "$needle" "$file" >/dev/null 2>&1; then
    printf 'FAIL: %s\nmissing: %s\nfile: %s\n' "$message" "$needle" "$file" >&2
    sed -n '1,120p' "$file" >&2 || true
    exit 1
  fi
}

assert_empty_file() {
  file=$1
  message=$2

  if [ -s "$file" ]; then
    printf 'FAIL: %s\nfile was not empty: %s\n' "$message" "$file" >&2
    sed -n '1,120p' "$file" >&2 || true
    exit 1
  fi
}

assert_path_absent() {
  path=$1
  message=$2

  if [ -e "$path" ]; then
    printf 'FAIL: %s\npath still exists: %s\n' "$message" "$path" >&2
    exit 1
  fi
}

run_ok() {
  name=$1
  shift
  "$@" >"$tmp_root/$name.out" 2>"$tmp_root/$name.err" || {
    sed -n '1,120p' "$tmp_root/$name.out" >&2 || true
    sed -n '1,120p' "$tmp_root/$name.err" >&2 || true
    fail "$name should have succeeded"
  }
  pass_count=$((pass_count + 1))
}

run_fail() {
  name=$1
  shift
  if "$@" >"$tmp_root/$name.out" 2>"$tmp_root/$name.err"; then
    sed -n '1,120p' "$tmp_root/$name.out" >&2 || true
    sed -n '1,120p' "$tmp_root/$name.err" >&2 || true
    fail "$name should have failed"
  fi
  pass_count=$((pass_count + 1))
}

make_app() {
  app_dir=$1
  mkdir -p "$app_dir/scripts" "$app_dir/config"
  cp "$repo_root/ssd.sh" "$app_dir/ssd.sh"
  chmod +x "$app_dir/ssd.sh"
  printf '%s\n' 'b100411d-8397-45fa-a4c6-0464359cb972' >"$app_dir/config/drive.uuid"

  cat >"$app_dir/scripts/find_device.sh" <<'EOF'
#!/bin/sh
case "${PBG_MOCK_FIND_MODE:-one}" in
  one) printf '%s\n' '/dev/block/sdg1' ;;
  none) exit 1 ;;
  many)
    printf '%s\n' '/dev/block/sdg1'
    printf '%s\n' '/dev/block/sdh1'
    ;;
esac
EOF

  cat >"$app_dir/scripts/mount_ext4.sh" <<'EOF'
#!/bin/sh
printf 'mount:%s\n' "$1" >>"$PBG_TEST_LOG"
EOF

  cat >"$app_dir/scripts/unmount.sh" <<'EOF'
#!/bin/sh
printf '%s\n' 'unmount' >>"$PBG_TEST_LOG"
EOF
}

with_test_env() {
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG=$1 \
  "$@"
}

app_with_spaces="$tmp_root/app with spaces"
make_app "$app_with_spaces"
log_file="$tmp_root/actions.log"
mounts_file="$tmp_root/proc mounts"
: >"$mounts_file"
export PBG_PROC_MOUNTS="$mounts_file"
export PBG_LOCK_DIR="$tmp_root/default.lock"

run_ok mount_from_other_directory env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG="$log_file" \
  "$app_with_spaces/ssd.sh" mount
assert_eq 'mount:/dev/block/sdg1' "$(sed -n '1p' "$log_file")" "mount should use the configured UUID device"
assert_path_absent "$PBG_LOCK_DIR" "lock should be released after successful mount"

run_ok status_from_path env \
  PATH="$app_with_spaces:$PATH" \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  ssd.sh status
assert_contains 'configured SSD found at /dev/block/sdg1' "$tmp_root/status_from_path.out" "status should work when script is resolved from PATH"

: >"$log_file"
printf '%s\n' '/dev/block/sdg1 /mnt/my_drive ext4 rw 0 0' >"$mounts_file"
run_ok unmount_scripts_layout env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG="$log_file" \
  "$app_with_spaces/ssd.sh" unmount
assert_eq 'unmount' "$(sed -n '1p' "$log_file")" "unmount should call the unmount helper"
: >"$mounts_file"

release_app="$tmp_root/release layout"
make_app "$release_app"
cp "$release_app/scripts/"*.sh "$release_app/"
rm -rf "$release_app/scripts"
: >"$log_file"
run_ok mount_release_layout env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG="$log_file" \
  "$release_app/ssd.sh" mount
assert_eq 'mount:/dev/block/sdg1' "$(sed -n '1p' "$log_file")" "release layout should find helpers next to ssd.sh"

run_fail missing_uuid_file env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_UUID_FILE="$tmp_root/missing.uuid" \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'Missing required file:' "$tmp_root/missing_uuid_file.err" "missing UUID should be explicit"

empty_uuid_file="$tmp_root/empty.uuid"
: >"$empty_uuid_file"
run_fail empty_uuid_file env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_UUID_FILE="$empty_uuid_file" \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'UUID file is empty:' "$tmp_root/empty_uuid_file.err" "empty UUID should be explicit"

invalid_uuid_file="$tmp_root/invalid.uuid"
printf '%s\n' 'not a uuid!' >"$invalid_uuid_file"
run_fail invalid_uuid_file env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_UUID_FILE="$invalid_uuid_file" \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'UUID file contains invalid characters:' "$tmp_root/invalid_uuid_file.err" "invalid UUID should be explicit"

multi_uuid_file="$tmp_root/multi.uuid"
printf '%s\n' 'b100411d-8397-45fa-a4c6-0464359cb972' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' >"$multi_uuid_file"
run_fail multi_uuid_file env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_UUID_FILE="$multi_uuid_file" \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'UUID file must contain exactly one UUID:' "$tmp_root/multi_uuid_file.err" "multi-line UUID should fail"

run_fail no_matching_device env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_MOCK_FIND_MODE=none \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'SSD block device not found' "$tmp_root/no_matching_device.err" "no UUID match should fail"

run_fail multiple_matching_devices env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_MOCK_FIND_MODE=many \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'Expected one SSD block device' "$tmp_root/multiple_matching_devices.err" "multiple UUID matches should fail"

: >"$log_file"
printf '%s\n' '/dev/block/sdg1 /mnt/my_drive ext4 rw 0 0' >"$mounts_file"
run_ok already_mounted_correct_device env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG="$log_file" \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'SSD already mounted at /mnt/my_drive' "$tmp_root/already_mounted_correct_device.out" "mount should be idempotent for the correct device"
assert_empty_file "$log_file" "mount helper should not run when correct device is already mounted"

: >"$log_file"
printf '%s\n' '/dev/block/sda33 /mnt/my_drive ext4 rw 0 0' >"$mounts_file"
run_fail busy_mountpoint_wrong_device env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG="$log_file" \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'Mount point busy with another device:' "$tmp_root/busy_mountpoint_wrong_device.err" "busy mount point should fail"
assert_empty_file "$log_file" "mount helper should not run for a busy wrong-device mount point"

: >"$log_file"
printf '%s\n' '/other/source /mnt/runtime/write/emulated/0/the_binding sdcardfs rw 0 0' >"$mounts_file"
run_fail busy_binding_wrong_source env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG="$log_file" \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'Binding mount point is already busy:' "$tmp_root/busy_binding_wrong_source.err" "busy binding mount point should fail"
assert_empty_file "$log_file" "mount helper should not run for a busy binding mount point"

: >"$log_file"
printf '%s\n' '/dev/block/sda33 /mnt/my_drive ext4 rw 0 0' >"$mounts_file"
run_fail unmount_wrong_device env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG="$log_file" \
  "$app_with_spaces/ssd.sh" unmount
assert_contains 'Refusing to unmount another device at /mnt/my_drive' "$tmp_root/unmount_wrong_device.err" "unmount should refuse wrong drive source"
assert_empty_file "$log_file" "unmount helper should not run for a wrong drive source"

: >"$mounts_file"
busy_lock="$tmp_root/busy.lock"
mkdir "$busy_lock"
run_fail busy_lock env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_LOCK_DIR="$busy_lock" \
  "$app_with_spaces/ssd.sh" mount
assert_contains 'Another SSD operation is already running:' "$tmp_root/busy_lock.err" "busy lock should fail safely"

: >"$mounts_file"
run_ok unmount_when_not_mounted env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG="$log_file" \
  "$app_with_spaces/ssd.sh" unmount
assert_contains 'SSD is not mounted' "$tmp_root/unmount_when_not_mounted.out" "unmount should be safe when nothing is mounted"

custom_helpers="$tmp_root/custom helpers"
make_app "$tmp_root/another app"
mkdir -p "$custom_helpers"
cp "$tmp_root/another app/scripts/"*.sh "$custom_helpers/"
: >"$log_file"
run_ok custom_helper_and_config_dirs env \
  PBG_ASSUME_ROOT=1 \
  PBG_ASSUME_GLOBAL_NAMESPACE=1 \
  PBG_SHELL=/bin/sh \
  PBG_TEST_LOG="$log_file" \
  PBG_HELPER_DIR="$custom_helpers" \
  PBG_CONFIG_DIR="$tmp_root/another app/config" \
  "$tmp_root/another app/ssd.sh" mount
assert_eq 'mount:/dev/block/sdg1' "$(sed -n '1p' "$log_file")" "custom helper/config dirs should be supported"

fake_bin="$tmp_root/fake bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-u" ]; then
  printf '%s\n' 2000
else
  /usr/bin/id "$@"
fi
EOF
cat >"$fake_bin/su" <<'EOF'
#!/bin/sh
if [ "${1:-}" != "-c" ]; then
  exit 2
fi
printf '%s\n' "$2" >"$PBG_SU_LOG"
EOF
cat >"$fake_bin/nsenter" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >"$PBG_NSENTER_LOG"
EOF
chmod +x "$fake_bin/id" "$fake_bin/su" "$fake_bin/nsenter"

su_log="$tmp_root/su command.log"
run_ok non_root_preserves_fallback_paths env \
  PATH="$fake_bin:$PATH" \
  PBG_SHELL=/bin/sh \
  PBG_SU_LOG="$su_log" \
  PBG_HELPER_DIR="$custom_helpers" \
  PBG_CONFIG_DIR="$tmp_root/another app/config" \
  PBG_DRIVE_MOUNT_DIR="/custom/mnt" \
  PBG_BINDING_DIR="/custom/binding" \
  "$tmp_root/another app/ssd.sh" mount
assert_contains "PBG_HELPER_DIR='$custom_helpers'" "$su_log" "su command should preserve custom helper dir"
assert_contains "PBG_CONFIG_DIR='$tmp_root/another app/config'" "$su_log" "su command should preserve custom config dir"
assert_contains "PBG_DRIVE_MOUNT_DIR='/custom/mnt'" "$su_log" "su command should preserve custom drive mount dir"
assert_contains "PBG_BINDING_DIR='/custom/binding'" "$su_log" "su command should preserve custom binding dir"

nsenter_log="$tmp_root/nsenter command.log"
run_ok namespace_fallback_uses_nsenter env \
  PBG_ASSUME_ROOT=1 \
  PBG_FORCE_NAMESPACE_SWITCH=1 \
  PBG_NSENTER="$fake_bin/nsenter" \
  PBG_NSENTER_LOG="$nsenter_log" \
  PBG_SHELL=/bin/sh \
  "$app_with_spaces/ssd.sh" status
assert_contains '-t 1 -m -- /bin/sh' "$nsenter_log" "namespace fallback should use nsenter"

run_fail namespace_fallback_requires_nsenter env \
  PATH="/usr/bin:/bin" \
  PBG_ASSUME_ROOT=1 \
  PBG_FORCE_NAMESPACE_SWITCH=1 \
  PBG_NSENTER="$tmp_root/missing-nsenter" \
  PBG_SHELL=/bin/sh \
  "$app_with_spaces/ssd.sh" status
assert_contains 'nsenter is required to enter the global mount namespace' "$tmp_root/namespace_fallback_requires_nsenter.err" "missing nsenter should fail fast"

printf 'ok - %s tests passed\n' "$pass_count"
