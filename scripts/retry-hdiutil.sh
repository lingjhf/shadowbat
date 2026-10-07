#!/bin/sh
# DiskImages can briefly hold a freshly created image while system services scan it.
# Retry only contention; malformed images and other failures remain fatal.
hdiutil_with_retry() {
  task_hdiutil_attempt=1
  while :; do
    task_hdiutil_output=$(mktemp)
    if hdiutil "$@" >"$task_hdiutil_output" 2>&1; then
      cat "$task_hdiutil_output"
      rm -f "$task_hdiutil_output"
      return 0
    else
      task_hdiutil_result=$?
    fi
    cat "$task_hdiutil_output" >&2
    if test "$task_hdiutil_attempt" -ge 5 ||
       ! grep -Eiq 'Resource temporarily unavailable|Resource busy|资源暂时不可用|资源忙' "$task_hdiutil_output"; then
      rm -f "$task_hdiutil_output"
      return "$task_hdiutil_result"
    fi
    rm -f "$task_hdiutil_output"
    printf 'DiskImages resource contention; retrying attempt %s of 5\n' "$((task_hdiutil_attempt + 1))" >&2
    sleep 2
    task_hdiutil_attempt=$((task_hdiutil_attempt + 1))
  done
}
