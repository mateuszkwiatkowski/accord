# VM test matrix

`scripts/vm-test.sh` boots one throwaway VM per OS in this directory and runs
accord in it as root. It answers "does accord work on X?" on real systems with
real init systems and package managers, which unit tests on a Mac and Docker
containers cannot.

```sh
scripts/vm-test.sh                    # every OS, in parallel (~2 min when cached)
scripts/vm-test.sh debian alpine      # a subset
scripts/vm-test.sh --keep freebsd     # leave a VM running if a check fails
scripts/vm-test.sh ssh freebsd        # ...then look around in it
scripts/vm-test.sh up rocky           # boot a fresh VM and leave it running
scripts/vm-test.sh stop               # stop kept VMs
```

Output is a table of OS × check, and the script exits 1 if any cell is not
`PASS`. Logs: `zig-out/vm-test/<os>/<check>.log`, plus `run.log` (harness) and
`console.log` (serial console, for boot problems).

## Requirements

Apple silicon Mac: QEMU with HVF (`brew install qemu`), arm64 guests, Homebrew's
EDK2 firmware. 1-3 GB per OS for cached images in `~/.cache/accord-vm`
(`ACCORD_VM_CACHE`); each VM gets 2 vCPUs and 2 GB (`ACCORD_VM_CPUS`,
`ACCORD_VM_MEMORY`). No Zig in the guests and no root on the Mac.

## How it works

1. **Build on the Mac.** `zig build install test-bin -Dtarget=<TARGET>`
   cross-compiles `accord` and the unit test binary (`accord-test`) per
   target: `aarch64-linux-gnu`, `aarch64-linux-musl` (statically linked) and
   `aarch64-freebsd`.
2. **Fetch.** The official cloud image is downloaded once, checked against the
   checksum pinned in `<os>.conf`, and converted to a pristine qcow2.
3. **Boot.** A copy-on-write overlay of that image plus a cloud-init NoCloud
   seed (`CIDATA`) carrying a generated SSH key. Each OS has a fixed SSH port
   on 127.0.0.1 (`SSH_PORT`).
4. **Check.** Everything is copied to `/var/tmp/accord-vm` and `guest.sh` runs
   each check as root (`sudo`, `doas` or `su`, per `BECOME`).
5. **Tear down.** QEMU is killed and the overlay deleted. The disk is
   disposable, so there is no clean shutdown.

## Checks

| Check | Passes when |
| --- | --- |
| `unit` | the unit test binary passes as root (apt/dpkg/systemd tests skip where absent) |
| `detect` | the `os_family=… pkg_manager=… init_system=… user_tool=…` debug line equals `EXPECT_DETECT` |
| `files` | `files.zon`: dry run creates nothing; modes and owner/group by name are right; a second run applies 0; drift is repaired |
| `packages` | `package-cache.zon` refreshes the index; `tree` is installed, then removed, each idempotent and confirmed by the package database |
| `services` | `SERVICE` is started+enabled, stopped+disabled, started+enabled again, as reported by the init system itself; each idempotent |
| `users` | `users.zon` creates two groups (one with a fixed gid), a user in them and a file it owns, in one run; `users-exact.zon` drops a group; `users-shell.zon` changes the shell (must be refused on busybox); then the user (with home) and the groups are removed. Every step is checked against `/etc/passwd` and `/etc/group` and is idempotent |

A check stops at its first failure, so a failure hides any later assertion in
the same check.

## Current results

As of 2026-11-26, every cell passes. Treat any `FAIL` as a regression:

| OS | boot | unit | detect | files | packages | services | users |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Ubuntu 26.04 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| Debian 13 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| Rocky Linux 10 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| Alpine 3.24 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |
| FreeBSD 15.1 | PASS | PASS | PASS | PASS | PASS | PASS | PASS |

On Debian and Ubuntu the unit tests include the apt/dpkg/systemd integration
tests; elsewhere those 4 skip.

## Adding an OS

Copy a `.conf` and fill in:

- `IMAGE_URL`: a versioned URL rather than "latest", so runs are reproducible.
- `IMAGE_SHA`: `sha256:…` or `sha512:…`, from the distribution's checksum file
  fetched over HTTPS.
- `LOGIN` and `BECOME`: the image's default cloud-init user and how it gets
  root. `SEED=users` creates `LOGIN` explicitly, for images whose cloud-init has
  no default user (FreeBSD's nuageinit).
- `TARGET`: the Zig target triple.
- `SSH_PORT`: unused by the other confs.
- `EXPECT_DETECT`: what accord *should* detect, even if it does not yet.
- `SERVICE`: a service the image ships enabled and that is safe to stop.

## Gotchas

- **Use names that exist everywhere.** `files.zon` uses `daemon` as owner and
  group because it exists by name on every OS here. FreeBSD has no `root`
  group (it is `wheel`), and `nobody`'s group varies.
- **BSD gives new files their directory's group**, Linux the creator's
  primary group. A file without `.group` has an OS-dependent group.
- **Debian's genericcloud image has no cron**, hence `systemd-timesyncd`.
- **Alpine's busybox has a `tree` applet**, so `command -v tree` finds it even
  with the package removed. `guest.sh` asks the package database instead.
- **Alpine's cloud image has shadow** (`useradd`, `usermod`) only because
  cloud-init needs it. accord ignores it there and uses busybox, so the
  `users` check covers the tools a default Alpine has.
- **busybox `adduser -G grp` also lists the user as a member of `grp`**, their
  primary group. `guest.sh` leaves the primary group out when comparing
  memberships.
- **Alpine ships `crond` stopped and disabled**, the others running and enabled.
  The start/stop/start order covers both.
- **Rocky's `ls -l` appends `.`** (SELinux context). `guest.sh` strips it.
- **FreeBSD boots slowest**: about 2.5 minutes to SSH, against 15 seconds for
  the Linux images. The boot timeout is 15 minutes.
- **download.freebsd.org can stall.** If `fetch` hangs, download the same file
  from a mirror into `~/.cache/accord-vm/downloads/` yourself; the pinned
  checksum still verifies it.
