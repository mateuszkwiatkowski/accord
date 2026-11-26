#!/bin/sh
#
# Test accord on real VMs: one throwaway QEMU guest per OS in test/vm/*.conf,
# booted from the distribution's official arm64 cloud image.
#
# Apple silicon Mac only for now: QEMU with HVF, arm64 guests. accord and its
# unit test binary are cross-compiled on the Mac (`zig build install test-bin
# -Dtarget=...`), copied in, and run as root by test/vm/guest.sh, one check at
# a time. Every check passes or fails on its own, so the result is a map of
# what works on which OS, not a single verdict.
#
# Usage:
#   scripts/vm-test.sh [--keep] [os...]   run the matrix (default: every OS)
#   scripts/vm-test.sh fetch [os...]      download + verify images only
#   scripts/vm-test.sh ssh <os> [cmd]     shell into a running VM
#   scripts/vm-test.sh stop [os...]       stop running VMs
#   scripts/vm-test.sh clean              stop everything, delete the cache
#
# --keep leaves VMs that failed a check running, for `ssh`. VMs are otherwise
# killed when their checks finish: their disks are copy-on-write overlays over
# a pristine image, so nothing in them is worth a clean shutdown.
#
# Results: zig-out/vm-test/<os>/<check>.log, plus console.log and run.log.
# Images and VM disks: ~/.cache/accord-vm (ACCORD_VM_CACHE).
# Needs: qemu (brew install qemu), hdiutil, shasum, xz, ssh.

# Word splitting of $(all_os) is intended; vars like SEED come from the sourced .conf.
# shellcheck disable=SC1090,SC2046,SC2153

set -eu
REPO="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)"
CONF_DIR="$REPO/test/vm"
OUT="$REPO/zig-out/vm-test"
CACHE="${ACCORD_VM_CACHE:-$HOME/.cache/accord-vm}"
CPUS="${ACCORD_VM_CPUS:-2}"
MEMORY="${ACCORD_VM_MEMORY:-2048}"
DISK_SIZE=16G
FIRMWARE="${ACCORD_VM_FIRMWARE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
SSH_KEY="$CACHE/id_ed25519"
# The guest's working directory; test/vm/files.zon refers to it by path.
GUEST_DIR=/var/tmp/accord-vm
CHECKS="unit detect files packages services"
# FreeBSD's first boot upgrades the base system and reboots before sshd is up.
BOOT_TIMEOUT=900

info() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

all_os() {
	for f in "$CONF_DIR"/*.conf; do basename "$f" .conf; done
}

load_conf() {
	[ -f "$CONF_DIR/$1.conf" ] || fail "no such OS '$1' (have: $(all_os | tr '\n' ' '))"
	unset NAME IMAGE_URL IMAGE_SHA LOGIN BECOME SEED TARGET SSH_PORT EXPECT_DETECT SERVICE
	. "$CONF_DIR/$1.conf"
}

require_tools() {
	[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || fail "needs an Apple silicon Mac"
	for t in qemu-system-aarch64 qemu-img hdiutil shasum xz ssh ssh-keygen zig; do
		command -v "$t" > /dev/null || fail "$t not found"
	done
	[ -r "$FIRMWARE" ] || fail "EFI firmware not found at $FIRMWARE"
}

# The macOS ssh-agent can hold keys whose signing hangs, and ~/.ssh/config may
# add anything: use only our own key and no user config.
vm_ssh() {
	os="$1"
	shift
	env -u SSH_AUTH_SOCK ssh -F /dev/null -p "$SSH_PORT" -i "$SSH_KEY" \
		-o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
		-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10 \
		-o ServerAliveInterval=30 "$LOGIN@127.0.0.1" "$@"
}

# Wrap a guest command so it runs as root.
as_root() {
	case "$BECOME" in
	sudo) echo "sudo $1" ;;
	doas) echo "doas $1" ;;
	su) echo "su -m root -c '$1'" ;;
	*) fail "unknown BECOME '$BECOME'" ;;
	esac
}

# ------------------------------------------------------------------ fetch ---

# Golden images are named after their checksum, so editing a .conf to a new
# image fetches it instead of reusing the old one.
golden() {
	echo "$CACHE/images/$1-$(echo "$IMAGE_SHA" | cut -d: -f2 | cut -c1-12).qcow2"
}

fetch() {
	os="$1"
	load_conf "$os"
	g="$(golden "$os")"
	[ -s "$g" ] && return 0
	mkdir -p "$CACHE/downloads" "$CACHE/images"
	file="$CACHE/downloads/$(basename "$IMAGE_URL")"
	if [ ! -s "$file" ]; then
		info "$os: downloading $IMAGE_URL"
		curl -fL --no-progress-meter --retry 3 -C - "$IMAGE_URL" -o "$file.part"
		mv "$file.part" "$file"
	fi
	algo="${IMAGE_SHA%%:*}"
	expected="${IMAGE_SHA#*:}"
	actual="$(shasum -a "${algo#sha}" "$file" | awk '{print $1}')"
	if [ "$expected" != "$actual" ]; then
		rm -f "$file"
		fail "$os: checksum mismatch for $file: expected $expected, got $actual"
	fi
	info "$os: checksum verified, converting to qcow2"
	src="$file"
	case "$file" in
	*.xz)
		src="$CACHE/downloads/$os.raw"
		xz -dc "$file" > "$src"
		;;
	esac
	qemu-img convert -O qcow2 "$src" "$g.part"
	[ "$src" = "$file" ] || rm -f "$src"
	mv "$g.part" "$g"
}

# ------------------------------------------------------------------ build ---

build_target() {
	info "building accord and its tests for $1"
	(cd "$REPO" && zig build install test-bin -Dtarget="$1" --prefix "$OUT/build/$1")
}

# What gets copied into the guest.
stage() {
	os="$1"
	s="$OUT/$os/stage"
	rm -rf "$s"
	mkdir -p "$s"
	cp "$OUT/build/$TARGET/bin/accord" "$OUT/build/$TARGET/bin/accord-test" "$s/"
	cp "$CONF_DIR"/*.zon "$CONF_DIR/guest.sh" "$CONF_DIR/source.txt" "$s/"
	cp "$CONF_DIR/$os.conf" "$s/vm.conf"
}

# -------------------------------------------------------------------- run ---

# cloud-init NoCloud seed; the volume label must be CIDATA. Linux images have a
# default user that gets the key and passwordless sudo/doas. FreeBSD's
# nuageinit has none, so SEED=users creates LOGIN explicitly.
build_seed() {
	os="$1"
	seed="$CACHE/run/$os/seed"
	mkdir -p "$seed"
	key="$(cat "$SSH_KEY.pub")"
	if [ "$SEED" = users ]; then
		cat > "$seed/user-data" <<-EOF
			#cloud-config
			ssh_pwauth: false
			users:
			  - name: $LOGIN
			    groups: wheel
			    shell: /bin/sh
			    ssh_authorized_keys:
			      - $key
		EOF
	else
		cat > "$seed/user-data" <<-EOF
			#cloud-config
			ssh_pwauth: false
			ssh_authorized_keys:
			  - $key
		EOF
	fi
	cat > "$seed/meta-data" <<-EOF
		instance-id: accord-vm-$os
		local-hostname: accord-$os
	EOF
	rm -f "$seed.iso"
	hdiutil makehybrid -quiet -iso -joliet -default-volume-name CIDATA -o "$seed.iso" "$seed"
}

stop_vm() {
	pidfile="$CACHE/run/$1/qemu.pid"
	if [ -f "$pidfile" ]; then
		pid="$(cat "$pidfile")"
		kill "$pid" 2> /dev/null || true
		i=0
		while kill -0 "$pid" 2> /dev/null && [ "$i" -lt 20 ]; do
			sleep 0.5
			i=$((i + 1))
		done
		kill -9 "$pid" 2> /dev/null || true
		rm -f "$pidfile"
	fi
}

boot() {
	os="$1"
	run="$CACHE/run/$os"
	stop_vm "$os"
	rm -rf "$run"
	mkdir -p "$run"
	qemu-img create -q -f qcow2 -b "$(golden "$os")" -F qcow2 "$run/disk.qcow2" "$DISK_SIZE"
	build_seed "$os"
	info "$os: booting (ssh port $SSH_PORT, console: $OUT/$os/console.log)"
	qemu-system-aarch64 -machine virt,accel=hvf -cpu host -smp "$CPUS" -m "$MEMORY" \
		-bios "$FIRMWARE" \
		-drive "if=virtio,file=$run/disk.qcow2,format=qcow2,cache=writeback" \
		-drive "if=virtio,file=$run/seed.iso,format=raw,readonly=on" \
		-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
		-device virtio-net-pci,netdev=n0 \
		-device virtio-rng-pci \
		-display none -monitor none -serial "file:$OUT/$os/console.log" \
		-daemonize -pidfile "$run/qemu.pid"
}

# QEMU accepts the forwarded port before the guest listens, so probe sshd
# itself rather than the port.
wait_for_ssh() {
	os="$1"
	start="$(date +%s)"
	while [ $(($(date +%s) - start)) -lt "$BOOT_TIMEOUT" ]; do
		if vm_ssh "$os" true 2> /dev/null; then
			info "$os: ssh up after $(($(date +%s) - start))s"
			return 0
		fi
		sleep 5
	done
	return 1
}

# Boot one OS and run every check in it. Runs in the background, one per OS;
# all output goes to $OUT/<os>/run.log, verdicts to <check>.status.
run_os() {
	os="$1"
	load_conf "$os"
	for c in boot $CHECKS; do echo "-" > "$OUT/$os/$c.status"; done

	# A subshell outside any conditional, so `set -e` still applies inside it
	# (it is ignored in functions called from `if` or `||`).
	set +e
	(
		set -e
		fetch "$os"
		stage "$os"
		boot "$os"
		wait_for_ssh "$os"
		info "$os: copying test files"
		(cd "$OUT/$os/stage" && COPYFILE_DISABLE=1 tar --no-xattrs -cf - .) |
			vm_ssh "$os" "rm -rf $GUEST_DIR && mkdir -p $GUEST_DIR && tar -xf - -C $GUEST_DIR"
	)
	rc=$?
	set -e
	if [ "$rc" -ne 0 ]; then
		echo FAIL > "$OUT/$os/boot.status"
		info "$os: setup failed; see $OUT/$os/run.log and console.log"
		stop_vm "$os"
		return 0
	fi
	echo PASS > "$OUT/$os/boot.status"

	failed=0
	for c in $CHECKS; do
		info "$os: $c"
		if vm_ssh "$os" "$(as_root "sh $GUEST_DIR/guest.sh $c")" > "$OUT/$os/$c.log" 2>&1; then
			echo PASS > "$OUT/$os/$c.status"
		else
			echo FAIL > "$OUT/$os/$c.status"
			failed=1
		fi
	done

	if [ "$KEEP" = 1 ] && [ "$failed" = 1 ]; then
		info "$os: kept running: scripts/vm-test.sh ssh $os"
	else
		stop_vm "$os"
		rm -f "$CACHE/run/$os/disk.qcow2"
	fi
}

summary() {
	printf '\n%-8s' OS
	for c in boot $CHECKS; do printf ' %-9s' "$c"; done
	printf '\n'
	rc=0
	for os in "$@"; do
		printf '%-8s' "$os"
		for c in boot $CHECKS; do
			s="$(cat "$OUT/$os/$c.status" 2> /dev/null || echo "?")"
			[ "$s" = PASS ] || rc=1
			printf ' %-9s' "$s"
		done
		printf '\n'
	done
	printf '\nLogs: %s/<os>/<check>.log\n' "$OUT"
	return "$rc"
}

cmd_run() {
	KEEP=0
	if [ "${1:-}" = --keep ]; then
		KEEP=1
		shift
	fi
	[ "$#" -gt 0 ] || set -- $(all_os)
	require_tools
	for os in "$@"; do load_conf "$os"; done

	mkdir -p "$CACHE/run"
	[ -s "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C accord-vm-test -f "$SSH_KEY"

	# Build once per target, up front, so parallel runs don't race on it.
	targets=""
	for os in "$@"; do
		load_conf "$os"
		case " $targets " in *" $TARGET "*) ;; *) targets="$targets $TARGET" ;; esac
	done
	for t in $targets; do build_target "$t"; done

	for os in "$@"; do
		rm -rf "${OUT:?}/$os"
		mkdir -p "$OUT/$os"
		run_os "$os" > "$OUT/$os/run.log" 2>&1 &
	done
	info "running $*; progress in $OUT/<os>/run.log"
	wait
	summary "$@"
}

cmd_fetch() {
	[ "$#" -gt 0 ] || set -- $(all_os)
	require_tools
	for os in "$@"; do fetch "$os"; done
}

cmd_ssh() {
	[ "$#" -ge 1 ] || fail "usage: $0 ssh <os> [cmd]"
	os="$1"
	shift
	load_conf "$os"
	vm_ssh "$os" "$@"
}

cmd_stop() {
	[ "$#" -gt 0 ] || set -- $(all_os)
	for os in "$@"; do stop_vm "$os"; done
}

cmd_clean() {
	cmd_stop
	rm -rf "$CACHE" "$OUT"
}

case "${1:-}" in
fetch | ssh | stop | clean)
	cmd="$1"
	shift
	"cmd_$cmd" "$@"
	;;
-h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
*) cmd_run "$@" ;;
esac
