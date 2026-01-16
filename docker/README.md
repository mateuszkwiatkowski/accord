# Docker Testing Infrastructure for accord

This directory contains Docker configurations for testing accord on various Linux distributions.

## Overview

The Docker testing infrastructure allows us to:
- Test accord on real Linux systems (proper platform detection)
- Verify system-specific operations (apt, systemd, etc.)
- Ensure cross-platform compatibility
- Prepare for CI/CD integration
- Test without modifying the host system

## Prerequisites

- **Docker Desktop** installed and running
- **Apple Silicon Mac** (arm64/aarch64) or compatible architecture
- **accord** source code in the parent directory

## Quick Start

```bash
# Run all tests automatically
./scripts/test-docker.sh

# Or run tests manually:

# 1. Build the image
docker build -t accord-test:debian -f docker/Dockerfile.debian .

# 2. Run tests
docker run --rm -v $(pwd):/workspace accord-test:debian zig build test

# 3. Test accord
docker run --rm -v $(pwd):/workspace accord-test:debian bash -c "
  zig build && 
  ./zig-out/bin/accord apply test/fixtures/debian-test.zon
"
```

## Available Images

### Debian Bookworm (`Dockerfile.debian`)

**Base**: `debian:bookworm-slim`  
**Zig Version**: 0.15.2 (aarch64-linux)  
**Platform Detection**:
- OS Family: `debian`
- Package Manager: `apt`
- Init System: `systemd`

**Installed Packages**:
- `git` - Version control (for future use)
- `zig` - Zig compiler 0.15.2

**Image Size**: ~150MB (after build)

**Build Time**: ~2-3 minutes (first build, downloads Zig)

**Usage**:
```bash
docker build -t accord-test:debian -f docker/Dockerfile.debian .
docker run -it --rm -v $(pwd):/workspace accord-test:debian
```

## Manual Testing

### Interactive Shell

Run an interactive shell in the container:

```bash
docker run -it --rm -v $(pwd):/workspace accord-test:debian
```

Inside the container, you can:

```bash
# Verify Zig is installed
zig version

# Build accord
zig build

# Run tests
zig build test

# Test system detection
./zig-out/bin/accord --version

# Apply a manifest
./zig-out/bin/accord apply examples/directories.zon

# Test with verbose logging
./zig-out/bin/accord apply test/fixtures/debian-test.zon --log-level=verbose

# Test dry-run mode
./zig-out/bin/accord apply test/fixtures/debian-test.zon --dry-run

# Verify created directories
ls -la /tmp/accord-docker-test/

# Check permissions
stat -c "%a %n" /tmp/accord-docker-test/*
```

### Testing Idempotency

Run accord twice and verify the second run shows no changes:

```bash
docker run --rm -v $(pwd):/workspace accord-test:debian bash -c "
  zig build &&
  ./zig-out/bin/accord apply test/fixtures/debian-test.zon &&
  echo '--- Running again for idempotency check ---' &&
  ./zig-out/bin/accord apply test/fixtures/debian-test.zon --log-level=normal
"
```

Expected output on second run:
```
Summary: 3 resources checked, 0 changes applied, 0 failed
```

### Testing Platform Detection

Verify that accord correctly detects Debian:

```bash
docker run --rm -v $(pwd):/workspace accord-test:debian bash -c "
  zig build && 
  ./zig-out/bin/accord apply test/fixtures/debian-test.zon --log-level=debug
"
```

Look for output showing:
- Detected OS: Debian
- Package manager: apt
- Init system: systemd

## Test Manifest

The Debian test manifest (`test/fixtures/debian-test.zon`) creates:

- `/tmp/accord-docker-test/` - Parent directory (mode 0755)
- `/tmp/accord-docker-test/subdir/` - Subdirectory (mode 0750)
- `/tmp/accord-docker-test/logs/` - Logs directory (mode 0700)

**Known Issue**: Due to HashMap ordering, subdirectories may fail if the parent directory is not created first. This is a documented limitation that will be addressed in a future version.

## Automated Test Script

The `scripts/test-docker.sh` script runs a complete test suite:

1. **Build** - Builds the Docker image
2. **Unit Tests** - Runs all Zig unit tests
3. **System Detection** - Verifies platform detection
4. **Apply Manifest** - Tests directory creation
5. **Idempotency** - Verifies no changes on second run
6. **Dry-run** - Tests preview mode

**Usage**:
```bash
./scripts/test-docker.sh
```

**Exit Codes**:
- `0` - All tests passed
- `1` - Test failure or error

## Troubleshooting

### Docker daemon not running

**Error**: `Cannot connect to the Docker daemon`

**Solution**: Start Docker Desktop

### Architecture mismatch

**Error**: `WARNING: The requested image's platform (linux/arm64) does not match`

**Solution**: Ensure you're using an ARM64/aarch64 system (Apple Silicon Mac) or modify the Dockerfile to download the appropriate Zig binary for your architecture.

Available Zig binaries:
- `zig-linux-aarch64-0.15.2.tar.xz` (ARM64)
- `zig-linux-x86_64-0.15.2.tar.xz` (x86-64)

### Image build fails

**Error**: `Failed to download Zig`

**Solution**: 
1. Check internet connection
2. Verify Zig download URL is correct
3. Check if ziglang.org is accessible

### Tests fail with "No such file or directory"

**Cause**: HashMap ordering issue with subdirectories

**This is expected behavior**. The test manifest includes subdirectories which may fail if the parent directory is not created first. This documents the known limitation.

**Solution**: Reorder resources in manifest (parent directories first) or wait for future fix using ArrayList instead of HashMap.

### Permission denied errors

**Error**: `error: PermissionDenied`

**This may be expected** if testing operations that require root privileges (like chown).

**Solution**: 
- For directory creation: Should work without root
- For owner/group changes: Not implemented yet (will show "not yet implemented")

## Performance

### Build Times

First build (downloads Zig):
- Debian: ~2-3 minutes

Subsequent builds (cached):
- Debian: ~10-20 seconds

### Test Execution

Full test suite: ~30-60 seconds
- Unit tests: ~10-20 seconds
- Integration tests: ~20-40 seconds

## Future Work

### Additional Images (Planned)

1. **Ubuntu** (`Dockerfile.ubuntu`)
   - Ubuntu 22.04 LTS
   - Same as Debian (apt, systemd)

2. **Fedora** (`Dockerfile.fedora`)
   - Fedora latest
   - Test dnf package manager
   - Test on RedHat family

3. **Alpine** (`Dockerfile.alpine`)
   - Alpine Linux
   - Test apk package manager
   - Test openrc init system

### CI/CD Integration

Once Docker testing is stable:
- Add GitHub Actions workflow
- Test matrix across multiple distributions
- Automated testing on push/PR
- Pre-built images on Docker Hub

### Optimizations

- Multi-architecture support (arm64 + amd64)
- Pre-built base images with Zig installed
- Layer caching optimization
- Parallel test execution

## Contributing

When adding support for a new platform:

1. Create `Dockerfile.<platform>` in this directory
2. Update this README with platform details
3. Add platform-specific test manifest in `test/fixtures/`
4. Update `scripts/test-docker.sh` to test new platform
5. Document platform-specific behaviors

## Resources

- [Zig Downloads](https://ziglang.org/download/)
- [Docker Documentation](https://docs.docker.com/)
- [Debian Docker Hub](https://hub.docker.com/_/debian)
- [accord Documentation](../README.md)
