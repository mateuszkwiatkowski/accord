#!/bin/sh
#
# Test accord on real VMs: one throwaway QEMU guest per OS in test/vm/*.conf,
# booted from the distribution's official cloud image.
#
# Apple silicon Mac only. arm64 guests (the default) run under HVF at native
# speed; x86_64 guests are emulated (TCG) and take many times longer. accord
# and its unit test binary are cross-compiled on the Mac (`zig build install
# test-bin -Dtarget=...`), copied in, and run as root by test/vm/guest.sh, one
# check at a time. Every check passes or fails on its own, so the result is a
# map of what works on which OS, not a single verdict.
#
# Usage:
#   scripts/vm-test.sh [options] [os...]          run the matrix (default: every OS)
#   scripts/vm-test.sh [--arch A] fetch [os...]   download + verify images only
#   scripts/vm-test.sh [--arch A] up <os>         boot a fresh VM and leave it running
#   scripts/vm-test.sh [--arch A] ssh <os> [cmd]  shell into a running VM
#   scripts/vm-test.sh [--arch A] stop [os...]    stop running VMs
#   scripts/vm-test.sh clean                      stop everything, delete the cache
#
# Options:
#   --arch aarch64|x86_64  guest architecture (default aarch64)
#   --release              test accord from the archives in zig-out/release (run
#                          scripts/release.sh first), and a ReleaseSafe unit
#                          test binary, instead of Debug builds
#   --keep                 leave VMs that failed a check running, for `ssh`
#
# VMs are otherwise killed when their checks finish: their disks are
# copy-on-write overlays over a pristine image, so nothing in them is worth a
# clean shutdown.
#
# Results: zig-out/vm-test/<os>/<check>.log (<os>-x86_64 for x86_64), plus
# console.log and run.log. Images and VM disks: ~/.cache/accord-vm
# (ACCORD_VM_CACHE). Needs: qemu (brew install qemu), hdiutil, shasum, xz, ssh.

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
SSH_KEY="$CACHE/id_ed25519"
# The guest's working directory; test/vm/files.zon refers to it by path.
GUEST_DIR=/var/tmp/accord-vm
CHECKS="unit detect files packages services users"
KEEP=0
RELEASE=0
ARCH=aarch64

info() { printf '==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

all_os() {
	for f in "$CONF_DIR"/*.conf; do basename "$f" .conf; done
}

# Settings that depend on --arch
set_arch() {
	case "$ARCH" in
	aarch64)
		QEMU=qemu-system-aarch64
		MACHINE="-machine virt,accel=hvf -cpu host"
		FIRMWARE="${ACCORD_VM_FIRMWARE:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}"
		FIRMWARE_ARGS="-bios $FIRMWARE"
		# FreeBSD's first boot generates keys and reboots before sshd is up
		BOOT_TIMEOUT=900
		PORT_OFFSET=0
		SUFFIX=""
		;;
	x86_64)
		QEMU=qemu-system-x86_64
		MACHINE="-machine q35 -accel tcg,thread=multi -cpu max"
		FIRMWARE="${ACCORD_VM_FIRMWARE:-/opt/homebrew/share/qemu/edk2-x86_64-code.fd}"
		# A flash image, too big for -bios on x86
		FIRMWARE_ARGS="-drive if=pflash,format=raw,readonly=on,file=$FIRMWARE"
		BOOT_TIMEOUT=3600
		PORT_OFFSET=100
		SUFFIX=-x86_64
		;;
	*) fail "unknown --arch '$ARCH' (aarch64 or x86_64)" ;;
	esac
}

# Read test/vm/<os>.conf and derive the per-architecture values: IMAGE_URL,
# IMAGE_SHA, ZIG_TARGET, SSH_PORT, and L, the label naming the VM's
# directories (the OS, plus -x86_64 for x86_64 guests).
load_conf() {
	[ -f "$CONF_DIR/$1.conf" ] || fail "no such OS '$1' (have: $(all_os | tr '\n' ' '))"
	unset NAME IMAGE_URL IMAGE_SHA LOGIN BECOME SEED TARGET SSH_PORT EXPECT_DETECT SERVICE
	unset IMAGE_URL_aarch64 IMAGE_SHA_aarch64 IMAGE_URL_x86_64 IMAGE_SHA_x86_64
	. "$CONF_DIR/$1.conf"
	eval "IMAGE_URL=\${IMAGE_URL_$ARCH:-}"
	eval "IMAGE_SHA=\${IMAGE_SHA_$ARCH:-}"
	[ -n "$IMAGE_URL" ] && [ -n "$IMAGE_SHA" ] || fail "$1.conf has no $ARCH image"
	ZIG_TARGET="$ARCH-$TARGET"
	SSH_PORT=$((SSH_PORT + PORT_OFFSET))
	L="$1$SUFFIX"
}

require_tools() {
	[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || fail "needs an Apple silicon Mac"
	for t in "$QEMU" qemu-img hdiutil shasum xz ssh ssh-keygen zig; do
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
		src="$CACHE/downloads/$L.raw"
		xz -dc "$file" > "$src"
		;;
	esac
	qemu-img convert -O qcow2 "$src" "$g.part"
	[ "$src" = "$file" ] || rm -f "$src"
	mv "$g.part" "$g"
}

# ------------------------------------------------------------------ build ---

# Build accord and the unit test binary for zig target $1 into
# $OUT/build/$1/bin. With --release, accord comes from the release archive
# (checked against SHA256SUMS) and the tests are built ReleaseSafe.
build_target() {
	dir="$OUT/build/$1"
	rm -rf "$dir"
	if [ "$RELEASE" = 0 ]; then
		info "building accord and its tests for $1"
		(cd "$REPO" && zig build install test-bin -Dtarget="$1" --prefix "$dir")
		return
	fi

	version="$(sed -n 's/^ *\.version = "\(.*\)",$/\1/p' "$REPO/build.zig.zon")"
	name="accord-$version-${1%%.*}" # drop the glibc version
	release="$REPO/zig-out/release"
	[ -f "$release/$name.tar.gz" ] || fail "no $release/$name.tar.gz; run scripts/release.sh $version"
	info "using $name.tar.gz, building ReleaseSafe tests for $1"
	(cd "$release" && grep " $name.tar.gz\$" SHA256SUMS | shasum -a 256 -c -) > /dev/null ||
		fail "$name.tar.gz does not match SHA256SUMS"
	(cd "$REPO" && zig build test-bin -Doptimize=ReleaseSafe -Dtarget="$1" --prefix "$dir")
	tar -xzOf "$release/$name.tar.gz" "$name/bin/accord" > "$dir/bin/accord"
	chmod 755 "$dir/bin/accord"
}

# What gets copied into the guest.
stage() {
	os="$1"
	s="$OUT/$L/stage"
	rm -rf "$s"
	mkdir -p "$s"
	cp "$OUT/build/$ZIG_TARGET/bin/accord" "$OUT/build/$ZIG_TARGET/bin/accord-test" "$s/"
	cp "$CONF_DIR"/*.zon "$CONF_DIR/guest.sh" "$CONF_DIR/source.txt" "$s/"
	cp "$CONF_DIR/$os.conf" "$s/vm.conf"
}

# -------------------------------------------------------------------- run ---

# cloud-init NoCloud seed; the volume label must be CIDATA. Linux images have a
# default user that gets the key and passwordless sudo/doas. FreeBSD's
# nuageinit has none, so SEED=users creates LOGIN explicitly.
build_seed() {
	os="$1"
	seed="$CACHE/run/$L/seed"
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

# Stop the VM labelled $1
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
	run="$CACHE/run/$L"
	stop_vm "$L"
	rm -rf "$run"
	mkdir -p "$run"
	qemu-img create -q -f qcow2 -b "$(golden "$os")" -F qcow2 "$run/disk.qcow2" "$DISK_SIZE"
	build_seed "$os"
	info "$L: booting (ssh port $SSH_PORT, console: $OUT/$L/console.log)"
	# shellcheck disable=SC2086 # MACHINE and FIRMWARE_ARGS are lists of options
	"$QEMU" $MACHINE -smp "$CPUS" -m "$MEMORY" $FIRMWARE_ARGS \
		-drive "if=virtio,file=$run/disk.qcow2,format=qcow2,cache=writeback" \
		-drive "if=virtio,file=$run/seed.iso,format=raw,readonly=on" \
		-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:$SSH_PORT-:22" \
		-device virtio-net-pci,netdev=n0 \
		-device virtio-rng-pci \
		-display none -monitor none -serial "file:$OUT/$L/console.log" \
		-daemonize -pidfile "$run/qemu.pid"
}

# QEMU accepts the forwarded port before the guest listens, so probe sshd
# itself rather than the port.
wait_for_ssh() {
	os="$1"
	start="$(date +%s)"
	while [ $(($(date +%s) - start)) -lt "$BOOT_TIMEOUT" ]; do
		if vm_ssh "$os" true 2> /dev/null; then
			info "$L: ssh up after $(($(date +%s) - start))s"
			return 0
		fi
		sleep 5
	done
	return 1
}

# Boot one OS and run every check in it. Runs in the background, one per OS;
# all output goes to $OUT/<label>/run.log, verdicts to <check>.status.
run_os() {
	os="$1"
	load_conf "$os"
	for c in boot $CHECKS; do echo "-" > "$OUT/$L/$c.status"; done

	# A subshell outside any conditional, so `set -e` still applies inside it
	# (it is ignored in functions called from `if` or `||`).
	set +e
	(
		set -e
		stage "$os"
		boot "$os"
		wait_for_ssh "$os"
		info "$L: copying test files"
		(cd "$OUT/$L/stage" && COPYFILE_DISABLE=1 tar --no-xattrs -cf - .) |
			vm_ssh "$os" "rm -rf $GUEST_DIR && mkdir -p $GUEST_DIR && tar -xf - -C $GUEST_DIR"
	)
	rc=$?
	set -e
	if [ "$rc" -ne 0 ]; then
		echo FAIL > "$OUT/$L/boot.status"
		info "$L: setup failed; see $OUT/$L/run.log and console.log"
		stop_vm "$L"
		return 0
	fi
	echo PASS > "$OUT/$L/boot.status"

	failed=0
	for c in $CHECKS; do
		info "$L: $c"
		if vm_ssh "$os" "$(as_root "sh $GUEST_DIR/guest.sh $c")" > "$OUT/$L/$c.log" 2>&1; then
			echo PASS > "$OUT/$L/$c.status"
		else
			echo FAIL > "$OUT/$L/$c.status"
			failed=1
		fi
	done

	if [ "$KEEP" = 1 ] && [ "$failed" = 1 ]; then
		info "$L: kept running: scripts/vm-test.sh --arch $ARCH ssh $os"
	else
		stop_vm "$L"
		rm -f "$CACHE/run/$L/disk.qcow2"
	fi
}

summary() {
	printf '\n%-18s' OS
	for c in boot $CHECKS; do printf ' %-9s' "$c"; done
	printf '\n'
	rc=0
	for os in "$@"; do
		load_conf "$os"
		printf '%-18s' "$L"
		for c in boot $CHECKS; do
			s="$(cat "$OUT/$L/$c.status" 2> /dev/null || echo "?")"
			[ "$s" = PASS ] || rc=1
			printf ' %-9s' "$s"
		done
		printf '\n'
	done
	printf '\nLogs: %s/<os>/<check>.log (%s %s)\n' "$OUT" "$ARCH" \
		"$([ "$RELEASE" = 1 ] && echo "release archives" || echo "debug build")"
	return "$rc"
}

cmd_run() {
	[ "$#" -gt 0 ] || set -- $(all_os)
	require_tools
	for os in "$@"; do load_conf "$os"; done

	mkdir -p "$CACHE/run"
	[ -s "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C accord-vm-test -f "$SSH_KEY"

	# Build once per target, up front, so parallel runs don't race on it.
	targets=""
	for os in "$@"; do
		load_conf "$os"
		case " $targets " in *" $ZIG_TARGET "*) ;; *) targets="$targets $ZIG_TARGET" ;; esac
	done
	for t in $targets; do build_target "$t"; done

	# Fetch up front too: several OSes can share an image (debian-musl)
	for os in "$@"; do fetch "$os"; done

	for os in "$@"; do
		load_conf "$os"
		rm -rf "${OUT:?}/$L"
		mkdir -p "$OUT/$L"
		run_os "$os" > "$OUT/$L/run.log" 2>&1 &
	done
	info "running $* ($ARCH); progress in $OUT/<os>/run.log"
	wait
	summary "$@"
}

cmd_up() {
	[ "$#" -eq 1 ] || fail "usage: $0 up <os>"
	require_tools
	load_conf "$1"
	mkdir -p "$CACHE/run" "$OUT/$L"
	[ -s "$SSH_KEY" ] || ssh-keygen -q -t ed25519 -N '' -C accord-vm-test -f "$SSH_KEY"
	fetch "$1"
	boot "$1"
	wait_for_ssh "$1" || fail "$L did not boot; see $OUT/$L/console.log"
	info "$L is up: $0 --arch $ARCH ssh $1"
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
	for os in "$@"; do
		load_conf "$os"
		stop_vm "$L"
	done
}

cmd_clean() {
	for ARCH in aarch64 x86_64; do
		set_arch
		cmd_stop
	done
	rm -rf "$CACHE" "$OUT"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
	--keep) KEEP=1 ;;
	--release) RELEASE=1 ;;
	--arch)
		[ "$#" -ge 2 ] || fail "--arch needs aarch64 or x86_64"
		ARCH="$2"
		shift
		;;
	--arch=*) ARCH="${1#*=}" ;;
	-*) break ;;
	*) break ;;
	esac
	shift
done
set_arch

case "${1:-}" in
fetch | up | ssh | stop | clean)
	cmd="$1"
	shift
	"cmd_$cmd" "$@"
	;;
-h | --help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' ;;
*) cmd_run "$@" ;;
esac
