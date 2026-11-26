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
	# Exact bytes: the manifest's \n escape must be decoded
	printf 'hello from accord\n' | cmp -s - "$dir/content.txt" || fail "content.txt differs"
	cmp -s source.txt "$dir/copied.txt" || fail "copied.txt differs from its source"

	step "apply again (idempotency)"
	accord apply files.zon
	assert_idempotent files.zon

	step "drift is repaired"
	chmod 0644 "$dir/content.txt"
	echo tampered > "$dir/content.txt"
	accord apply files.zon
	assert_perms "$dir/content.txt" "-rw-r----- daemon daemon"
	printf 'hello from accord\n' | cmp -s - "$dir/content.txt" || fail "content.txt not restored"

	rm -rf "$dir"
}

# Ask the package database directly, independently of accord's own check.
# Not `command -v`: Alpine's busybox has a tree applet of its own.
pkg_installed() {
	if command -v dpkg-query > /dev/null; then
		dpkg-query -W -f='${Status}' "$1" 2> /dev/null | grep -q "install ok installed"
	elif command -v rpm > /dev/null; then
		rpm -q "$1" > /dev/null 2>&1
	elif command -v apk > /dev/null; then
		apk info -e "$1" > /dev/null 2>&1
	else
		pkg info -e "$1" > /dev/null 2>&1
	fi
}

check_packages() {
	step "refresh package cache"
	accord apply package-cache.zon

	step "install tree"
	accord apply packages.zon
	pkg_installed tree || fail "tree is not installed"

	step "install again (idempotency)"
	accord apply packages.zon
	assert_idempotent packages.zon

	step "remove tree"
	accord apply packages-absent.zon
	! pkg_installed tree || fail "tree is still installed"

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

# Apply a service manifest, check the init system agrees, and check a second
# run is a no-op.
service_to() {
	step "$SERVICE -> $1 $2"
	accord apply "service-$1.zon"
	[ "$(service_state "$SERVICE")" = "$1 $2" ] ||
		fail "$SERVICE is '$(service_state "$SERVICE")'"
	accord apply "service-$1.zon"
	assert_idempotent "service-$1.zon"
}

# Start, stop, start: every transition runs at least once, whatever state
# the image ships the service in, and it ends up running.
check_services() {
	echo "$SERVICE before: $(service_state "$SERVICE")"
	service_manifest stopped false
	service_manifest running true

	service_to running enabled
	service_to stopped disabled
	service_to running enabled
}

case "${1:-}" in
unit | detect | files | packages | services) "check_$1" ;;
*)
	echo "usage: $0 unit|detect|files|packages|services" >&2
	exit 2
	;;
esac
