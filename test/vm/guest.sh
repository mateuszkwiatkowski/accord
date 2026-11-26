#!/bin/sh
#
# Runs inside a test VM, as root, from the directory scripts/vm-test.sh copied
# everything into. One check per invocation; exit status is the verdict and
# stdout/stderr is the check's log.
#
#   sh guest.sh unit|detect|files|packages|services
#
# vm.conf (the OS's test/vm/<os>.conf) supplies EXPECT_DETECT and SERVICE.

# shellcheck disable=SC1091,SC2012
set -u
cd "$(dirname "$0")" || exit 1
. ./vm.conf

ACCORD=./accord

fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

# Run accord, show its output, and fail the check if it exits non-zero.
accord() {
	printf '$ accord %s\n' "$*"
	"$ACCORD" "$@" > accord.out 2>&1
	rc=$?
	cat accord.out
	[ "$rc" -eq 0 ] || fail "accord $* exited $rc"
}

# The second run of a manifest must change nothing.
assert_idempotent() {
	grep -q 'Summary: .* 0 applied, 0 failed' accord.out ||
		fail "second run of $1 was not a no-op"
}

# "mode owner group" of a path, from ls -ld: portable across GNU, BSD and
# busybox, unlike stat(1). The trailing SELinux/ACL marker (Rocky's ".") is
# dropped.
perms() {
	ls -ld "$1" | awk '{sub(/[.+@]$/, "", $1); print $1, $3, $4}'
}

# $2 is a case pattern
assert_perms() {
	got="$(perms "$1")"
	# shellcheck disable=SC2254
	case "$got" in $2) ;; *) fail "$1: expected '$2', got '$got'" ;; esac
	echo "ok: $1 $got"
}

check_unit() {
	./accord-test
}

check_detect() {
	printf '.{}\n' > empty.zon
	accord --log-level=debug apply empty.zon
	got="$(sed -n 's/^\[DEBUG\] \(os_family=.*\)$/\1/p' accord.out)"
	[ "$got" = "$EXPECT_DETECT" ] || fail "expected '$EXPECT_DETECT', got '$got'"
	echo "ok: $got"
}

check_files() {
	dir=/var/tmp/accord-vm-files
	rm -rf "$dir"

	step "dry run creates nothing"
	accord --dry-run apply files.zon
	[ ! -e "$dir" ] || fail "dry run created $dir"

	step "apply"
	accord apply files.zon
	assert_perms "$dir" "drwxr-x--- daemon daemon"
	assert_perms "$dir/content.txt" "-rw-r----- daemon daemon"
	# No group in the manifest: BSD gives new files the directory's group,
	# Linux the creator's, so only mode and owner are asserted.
	assert_perms "$dir/copied.txt" "-rw------- root *"
	[ "$(cat "$dir/content.txt")" = "hello from accord" ] || fail "content.txt differs"
	cmp -s source.txt "$dir/copied.txt" || fail "copied.txt differs from its source"

	step "apply again (idempotency)"
	accord apply files.zon
	assert_idempotent files.zon

	step "drift is repaired"
	chmod 0644 "$dir/content.txt"
	echo tampered > "$dir/content.txt"
	accord apply files.zon
	assert_perms "$dir/content.txt" "-rw-r----- daemon daemon"
	[ "$(cat "$dir/content.txt")" = "hello from accord" ] || fail "content.txt not restored"

	rm -rf "$dir"
}

check_packages() {
	if command -v apt-get > /dev/null; then
		step "refresh apt cache"
		accord apply apt-update.zon
	fi

	step "install tree"
	accord apply packages.zon
	# A fresh shell each time: this one may have hashed tree's path.
	sh -c "command -v tree" > /dev/null || fail "tree is not installed"

	step "install again (idempotency)"
	accord apply packages.zon
	assert_idempotent packages.zon

	step "remove tree"
	accord apply packages-absent.zon
	! sh -c "command -v tree" > /dev/null || fail "tree is still installed"

	step "remove again (idempotency)"
	accord apply packages-absent.zon
	assert_idempotent packages-absent.zon
}

# Ask the init system directly, independently of accord's own check.
# Prints "running|stopped enabled|disabled".
service_state() {
	if command -v systemctl > /dev/null; then
		systemctl is-active --quiet "$1" && r=running || r=stopped
		systemctl is-enabled --quiet "$1" && e=enabled || e=disabled
	elif command -v rc-service > /dev/null; then
		rc-service "$1" status > /dev/null 2>&1 && r=running || r=stopped
		rc-update show default | grep -qw "$1" && e=enabled || e=disabled
	else
		service "$1" status > /dev/null 2>&1 && r=running || r=stopped
		service "$1" enabled > /dev/null 2>&1 && e=enabled || e=disabled
	fi
	echo "$r $e"
}

service_manifest() {
	printf '.{\n    .services = .{\n        .@"%s" = .{ .state = .%s, .enabled = %s },\n    },\n}\n' \
		"$SERVICE" "$1" "$2" > "service-$1.zon"
}

check_services() {
	original="$(service_state "$SERVICE")"
	echo "$SERVICE before: $original"
	service_manifest stopped false
	service_manifest running true

	step "stop and disable $SERVICE"
	accord apply service-stopped.zon
	[ "$(service_state "$SERVICE")" = "stopped disabled" ] ||
		fail "$SERVICE is '$(service_state "$SERVICE")'"
	accord apply service-stopped.zon
	assert_idempotent service-stopped.zon

	step "start and enable $SERVICE"
	accord apply service-running.zon
	[ "$(service_state "$SERVICE")" = "running enabled" ] ||
		fail "$SERVICE is '$(service_state "$SERVICE")'"
	accord apply service-running.zon
	assert_idempotent service-running.zon
}

case "${1:-}" in
unit | detect | files | packages | services) "check_$1" ;;
*)
	echo "usage: $0 unit|detect|files|packages|services" >&2
	exit 2
	;;
esac
