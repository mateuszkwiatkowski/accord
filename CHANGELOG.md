# Changelog

All notable changes to accord. Versions follow [Semantic Versioning](https://semver.org);
the release workflow publishes the section of the tagged version as its release notes.

## [0.1.0] - unreleased

First release.

### Resources
- `directories` and `files`: mode, owner and group (names or numeric ids), content or a source file, atomic writes, removal
- `packages`: apt, dnf/yum, apk and pkg, with version pinning
- `services`: systemd, OpenRC and FreeBSD rc.d, running/stopped and enabled at boot
- `package_cache`: refresh the package index before installing (`apt_update` is accepted as an alias)
- `groups` and `users`: gid, uid, primary and supplementary groups (`membership = .append` or `.exact`), shell, home, removal; with only the tools each OS ships (useradd & co., busybox, pw)

### Manifests
- Parsed with Zig's ZON parser; unknown sections or attributes, wrong types and syntax errors stop accord before anything is applied (exit 2, with file:line:column)
- Sections apply in a fixed order: package cache, packages, groups, users, directories, files, services; resources within a section in manifest order

### Platforms
- Debian, Ubuntu, RHEL family (Rocky, Alma, Fedora), Alpine Linux and FreeBSD, on aarch64 and x86_64
- Release archives for Linux (glibc 2.34+ or static musl) and FreeBSD 14+, with signed checksums
