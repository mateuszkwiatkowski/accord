# accord

**Lightweight configuration management for UNIX systems.**

accord brings your system into accord with declarative manifests. Simple binary, clear syntax, promise theory. Built with Zig for safety and performance.

---

## Features

- **Lightweight**: Single binary, runs on-demand, clean exit codes
- **Declarative**: Describe desired state in ZON (Zig Object Notation)
- **Idempotent**: Run repeatedly, only makes necessary changes
- **Type-Safe**: Zig's compile-time guarantees prevent common errors
- **Sensible Defaults**: Minimal configuration for common operations
- **Cross-Platform**: Debian, Ubuntu, the RHEL family, Alpine and FreeBSD supported now; designed for macOS and the other BSDs
- **UNIX Philosophy**: Composable, focused tool with clear exit codes
- **Fail-Fast**: Stop on first error, or opt-out with `allow_failure`
- **Verbose**: Clear output showing exactly what's happening

---

## Quick Start

### Installation

#### From a release

Each [release](https://github.com/mateuszkwiatkowski/accord/releases) has one archive per platform, a `SHA256SUMS` file and its minisign signature:

| Archive | Runs on |
| --- | --- |
| `accord-VERSION-{aarch64,x86_64}-linux-gnu.tar.gz` | Linux with glibc 2.34 or newer (RHEL 9+, Debian 12+, Ubuntu 22.04+) |
| `accord-VERSION-{aarch64,x86_64}-linux-musl.tar.gz` | Any Linux, Alpine included (static binary) |
| `accord-VERSION-{aarch64,x86_64}-freebsd.tar.gz` | FreeBSD 14 or newer |

On glibc systems prefer the `gnu` archive: the static `musl` binary reads users and groups only from `/etc/passwd` and `/etc/group`, so accounts from LDAP, sssd or other NSS sources are invisible to it (for `.owner`, `.group` and the user resource).

```bash
v=0.1.0 t=x86_64-linux-gnu
base=https://github.com/mateuszkwiatkowski/accord/releases/download/v$v
curl -fLO "$base/accord-$v-$t.tar.gz" -fLO "$base/SHA256SUMS" -fLO "$base/SHA256SUMS.minisig"

# Check the signature with minisign.pub from this repository, then the archive
minisign -Vm SHA256SUMS -p minisign.pub
sha256sum --ignore-missing -c SHA256SUMS

tar -xzf "accord-$v-$t.tar.gz"
sudo cp "accord-$v-$t/bin/accord" /usr/local/bin/
sudo cp -R "accord-$v-$t/share/man/." /usr/local/share/man/
```

Archives also carry GitHub build provenance: `gh attestation verify accord-$v-$t.tar.gz -R mateuszkwiatkowski/accord`.

#### From source

```bash
git clone https://github.com/mateuszkwiatkowski/accord
cd accord
mise install    # the pinned Zig toolchain (or install Zig 0.17.1 yourself)
zig build -Doptimize=ReleaseSafe --prefix /usr/local install   # binary and man pages
```

**Requirements**: Zig 0.17.1 (pinned in `mise.toml`; [mise](https://mise.jdx.dev) installs it automatically)

### Your First Manifest

Create a file `webserver.zon`:

```zig
.{
    .packages = .{
        .nginx = .{},  // Install nginx (state = .installed by default)
    },
    
    .files = .{
        .@"/var/www/html/index.html" = .{
            .content = "<h1>Hello from accord!</h1>",
            .mode = 0o644,
        },
    },
    
    .services = .{
        .nginx = .{},  // Ensure running and enabled at boot
    },
}
```

### Apply Configuration

```bash
# Check what would change (dry run)
sudo accord apply --dry-run webserver.zon

# Apply changes
sudo accord apply webserver.zon
```

Output:
```
[CHECK] Package nginx... not installed
[APPLY] Installing package nginx... done
[CHECK] File /var/www/html/index.html... not present
[APPLY] Writing file /var/www/html/index.html... done
[CHECK] Service nginx... stopped
[APPLY] Starting service nginx... done

Summary: 3 resources checked, 3 changes applied, 0 failed
```

Visit `http://localhost` - your web server is configured!

---

## Manifest Format

accord uses **ZON (Zig Object Notation)** for manifests. ZON is Zig's native data format - simple, clean, and type-safe.

### Basic Structure

```zig
.{
    .packages = .{ /* package resources */ },
    .files = .{ /* file resources */ },
    .directories = .{ /* directory resources */ },
    .services = .{ /* service resources */ },
    .users = .{ /* user resources */ },
    .groups = .{ /* group resources */ },
}
```

### Resource Types

#### Packages

Install or remove system packages.

```zig
.packages = .{
    .nginx = .{},  // Install (default)
    .git = .{},
    .apache2 = .{ .state = .absent },  // Remove
    .nodejs = .{ 
        .version = "18.0.0",  // Specific version (if supported by pkg manager)
    },
}
```

**Attributes**:
- `state`: `.installed` (default) or `.absent`
- `version`: Package version (optional)
- `allow_failure`: Continue if operation fails (default: `false`)

**Package Managers**: apt (Debian/Ubuntu), dnf and yum (RHEL family), apk (Alpine), pkg (FreeBSD). Future: pacman, brew.

To refresh the package index before installing (`apt-get update`, `dnf makecache`, `apk update`, `pkg update`), add `.package_cache = .{}` to the manifest. It runs before every other resource. `.apt_update = .{}` is accepted as an older name for it.

---

#### Files

Manage file content, permissions, and ownership.

```zig
.files = .{
    .@"/etc/myapp/config.ini" = .{
        .content = 
            \\[database]
            \\host = localhost
            \\port = 5432
        ,
        .mode = 0o644,
        .owner = "root",
        .group = "root",
    },
    
    .@"/etc/nginx/sites-enabled/myapp" = .{
        .source = "/etc/nginx/sites-available/myapp",  // Copy from file
        .mode = 0o644,
    },
    
    .@"/etc/old-config" = .{
        .state = .absent,  // Remove file
    },
}
```

**Attributes**:
- `path`: File path (specified as key with `@""` syntax)
- `content`: File content (multi-line strings with `\\`)
- `source`: Copy from this file instead of using `content`
- `mode`: Octal file permissions (e.g., `0o644`)
- `owner`: File owner (username)
- `group`: File group (group name)
- `state`: `.present` (default) or `.absent`
- `allow_failure`: Continue if operation fails

---

#### Directories

Ensure directories exist with correct permissions.

```zig
.directories = .{
    .@"/var/www" = .{
        .mode = 0o755,
        .owner = "www-data",
        .group = "www-data",
    },
    
    .@"/opt/myapp" = .{
        .mode = 0o750,
        .owner = "appuser",
    },
    
    .@"/tmp/old-data" = .{
        .state = .absent,  // Remove directory
    },
}
```

**Attributes**:
- `path`: Directory path (specified as key)
- `mode`: Octal directory permissions (e.g., `0o755`)
- `owner`: Directory owner
- `group`: Directory group
- `state`: `.present` (default) or `.absent`
- `allow_failure`: Continue if operation fails

---

#### Services

Manage system services (systemd, etc.).

```zig
.services = .{
    .nginx = .{},  // Running + enabled (defaults)
    
    .postgresql = .{
        .state = .running,
        .enabled = true,
    },
    
    .apache2 = .{
        .state = .stopped,   // Stop service
        .enabled = false,    // Disable at boot
    },
}
```

**Attributes**:
- `name`: Service name (specified as key)
- `state`: `.running` (default) or `.stopped`
- `enabled`: Start at boot, `true` (default) or `false`
- `allow_failure`: Continue if operation fails

**Init Systems**: systemd, OpenRC (Alpine), rc.d (FreeBSD). Future: sysvinit, launchd.

---

#### Users

Create, update and remove user accounts. Accounts get no usable password.

```zig
.users = .{
    .deployer = .{
        .uid = 1001,
        .group = "deployer",                // Primary group (must exist)
        .groups = .{ "docker", "www-data" }, // Supplementary groups
        .shell = "/bin/sh",
        .home = "/srv/deployer",
    },

    .ops = .{
        .groups = .{"wheel"},
        .membership = .exact,  // Also leave any group not listed
    },

    .olduser = .{ .state = .absent, .remove_home = true },
}
```

**Attributes**:
- `name`: Username (specified as key)
- `uid`: User ID (optional; the system picks one)
- `group`: Primary group (optional; the system default otherwise)
- `groups`: Supplementary groups, which must exist
- `membership`: `.append` (default) only adds the user to `groups`; `.exact` also removes them from every other supplementary group. The primary group is never touched.
- `shell`, `home`: optional; the system defaults apply when unset (usually `/bin/sh` and `/home/<name>`)
- `state`: `.present` (default) or `.absent`
- `remove_home`: with `.absent`, also delete the home directory (default: `false`)
- `allow_failure`: Continue if operation fails

**Tools**: `useradd`/`usermod`/`gpasswd` (Debian, Ubuntu, RHEL family), busybox `adduser`/`addgroup`/`deluser`/`delgroup` (Alpine), `pw` (FreeBSD). Nothing extra is installed.

**Not supported**: changing the uid of an existing user (error on every OS); on Alpine, changing an existing user's shell, home or primary group (busybox has no `usermod`). These are reported as errors rather than ignored. They work when the user is created.

---

#### Groups

Create and remove groups.

```zig
.groups = .{
    .appgroup = .{ .gid = 1001 },
    .developers = .{},
    .oldgroup = .{ .state = .absent },
}
```

**Attributes**:
- `name`: Group name (specified as key)
- `gid`: Group ID (optional). Changing the gid of an existing group is refused.
- `state`: `.present` (default) or `.absent`
- `allow_failure`: Continue if operation fails

Groups are applied before users, so a group cannot be removed in the same run as the users whose primary group it is: remove the users first.

---

### Common Patterns

#### Multi-Line Strings

Use `\\` for multi-line content:

```zig
.content = 
    \\line 1
    \\line 2
    \\line 3
,
```

#### Octal File Modes

Use `0o` prefix for octal:

```zig
.mode = 0o644,  // rw-r--r--
.mode = 0o755,  // rwxr-xr-x
.mode = 0o600,  // rw-------
```

#### Error Handling

By default, accord stops on first error (fail-fast). Override per-resource:

```zig
.packages = .{
    .critical_package = .{},  // Must succeed
    
    .optional_package = .{
        .allow_failure = true,  // Continue even if this fails
    },
}
```

---

## CLI Usage

### Commands

```bash
accord apply [OPTIONS] MANIFEST
```

Apply configuration from manifest file.

### Options

**`--dry-run, -n`**  
Show what would change without making modifications.

```bash
accord apply --dry-run manifest.zon
```

**`--log-level=LEVEL`**  
Set logging verbosity: `quiet`, `normal`, `verbose` (default), `debug`.

```bash
accord apply --log-level=quiet manifest.zon   # Only summary
accord apply --log-level=normal manifest.zon  # Changes only
accord apply --log-level=verbose manifest.zon # All checks (default)
accord apply --log-level=debug manifest.zon   # Debug details
```

**`--version, -V`**  
Show version information.

**`--help, -h`**  
Show help message.

### Exit Codes

accord uses UNIX-standard exit codes:

- **0**: Success - all resources satisfied or applied
- **1**: General error
- **2**: Invalid manifest (parse error); nothing is applied
- **4**: Resource operation failed

Use in scripts:

```bash
if accord apply manifest.zon; then
    echo "Configuration applied successfully"
else
    echo "Configuration failed with exit code $?"
fi
```

---

## Examples

### Web Server Setup

Complete nginx web server with SSL preparation:

```zig
// webserver.zon
.{
    .packages = .{
        .nginx = .{},
        .certbot = .{},
    },
    
    .directories = .{
        .@"/var/www" = .{
            .mode = 0o755,
            .owner = "www-data",
            .group = "www-data",
        },
        .@"/var/www/mysite" = .{
            .mode = 0o755,
            .owner = "www-data",
        },
    },
    
    .files = .{
        .@"/etc/nginx/sites-available/mysite" = .{
            .content = 
                \\server {
                \\    listen 80;
                \\    server_name mysite.com www.mysite.com;
                \\    root /var/www/mysite;
                \\    index index.html index.htm;
                \\
                \\    location / {
                \\        try_files $uri $uri/ =404;
                \\    }
                \\}
            ,
            .mode = 0o644,
            .owner = "root",
            .group = "root",
        },
        .@"/var/www/mysite/index.html" = .{
            .content = 
                \\<!DOCTYPE html>
                \\<html>
                \\<head><title>My Site</title></head>
                \\<body><h1>Welcome to my site!</h1></body>
                \\</html>
            ,
            .mode = 0o644,
            .owner = "www-data",
            .group = "www-data",
        },
    },
    
    .services = .{
        .nginx = .{},
    },
}
```

---

### Development Environment

Setup for a development workstation:

```zig
// devenv.zon
.{
    .packages = .{
        .git = .{},
        .@"build-essential" = .{},
        .curl = .{},
        .vim = .{},
        .tmux = .{},
        .docker = .{},
    },
    
    .users = .{
        .developer = .{
            .uid = 1000,
            .groups = .{ "sudo", "docker" },
            .shell = "/bin/bash",
            .home = "/home/developer",
        },
    },
    
    .directories = .{
        .@"/home/developer/projects" = .{
            .mode = 0o755,
            .owner = "developer",
            .group = "developer",
        },
        .@"/home/developer/.config" = .{
            .mode = 0o755,
            .owner = "developer",
        },
    },
    
    .files = .{
        .@"/home/developer/.gitconfig" = .{
            .content = 
                \\[user]
                \\    name = Developer
                \\    email = dev@example.com
                \\[core]
                \\    editor = vim
            ,
            .mode = 0o644,
            .owner = "developer",
            .group = "developer",
        },
    },
    
    .services = .{
        .docker = .{},
    },
}
```

---

### Database Server

PostgreSQL database setup:

```zig
// database.zon
.{
    .packages = .{
        .postgresql = .{},
        .@"postgresql-contrib" = .{},
    },
    
    .users = .{
        .dbadmin = .{
            .uid = 1001,
            .groups = .{ "postgres" },
            .shell = "/bin/bash",
        },
    },
    
    .directories = .{
        .@"/var/lib/postgresql/backups" = .{
            .mode = 0o700,
            .owner = "postgres",
            .group = "postgres",
        },
    },
    
    .files = .{
        .@"/etc/postgresql/14/main/pg_hba.conf" = .{
            .content = 
                \\# TYPE  DATABASE        USER            ADDRESS                 METHOD
                \\local   all             postgres                                peer
                \\local   all             all                                     peer
                \\host    all             all             127.0.0.1/32            md5
                \\host    all             all             ::1/128                 md5
            ,
            .mode = 0o640,
            .owner = "postgres",
            .group = "postgres",
        },
    },
    
    .services = .{
        .postgresql = .{},
    },
}
```

---

### Docker Host

Container host configuration:

```zig
// docker-host.zon
.{
    .packages = .{
        .docker = .{},
        .@"docker-compose" = .{},
    },
    
    .groups = .{
        .docker = .{ .gid = 999 },
    },
    
    .users = .{
        .deployer = .{
            .uid = 1001,
            .groups = .{ "docker", "sudo" },
            .shell = "/bin/bash",
        },
    },
    
    .directories = .{
        .@"/opt/docker" = .{
            .mode = 0o755,
            .owner = "deployer",
            .group = "docker",
        },
        .@"/opt/docker/volumes" = .{
            .mode = 0o755,
            .owner = "deployer",
        },
    },
    
    .files = .{
        .@"/etc/docker/daemon.json" = .{
            .content = 
                \\{
                \\  "log-driver": "json-file",
                \\  "log-opts": {
                \\    "max-size": "10m",
                \\    "max-file": "3"
                \\  }
                \\}
            ,
            .mode = 0o644,
            .owner = "root",
            .group = "root",
        },
    },
    
    .services = .{
        .docker = .{},
    },
}
```

---

## Platform Support

### Currently Supported

| OS | Packages | Services | Users and groups |
| --- | --- | --- | --- |
| Debian, Ubuntu | apt | systemd | useradd & co. |
| RHEL family (Rocky, Alma, Fedora) | dnf, yum | systemd | useradd & co. |
| Alpine Linux (musl) | apk | OpenRC | busybox (no changing an existing user's shell, home or primary group) |
| FreeBSD | pkg | rc.d | pw |

Files and directories work on all of them.

These are tested on real VMs of Ubuntu 26.04, Debian 13, Rocky Linux 10,
Alpine 3.24 and FreeBSD 15.1, on arm64 and x86_64, with the release archives.
See [test/vm/README.md](test/vm/README.md) for the current results.

### Roadmap

accord is designed for cross-platform support from the ground up.

**Planned**:
- Arch Linux (pacman)
- macOS (Homebrew + launchd)
- OpenBSD, NetBSD

See [AGENTS.md](AGENTS.md) for extensibility guide.

---

## Why accord?

### Strengths

**Simple**: Single binary, declarative manifests, no complex DSL or YAML. Run and exit cleanly.

**Type-Safe**: Zig's compile-time checks catch errors before runtime. ZON manifests are validated strictly.

**Fast**: Compiled binary with zero interpreter overhead. Near-instant execution.

**Idempotent**: Run repeatedly without side effects. Only makes necessary changes.

**Extensible**: Clean abstractions make adding platforms and resources straightforward. See [AGENTS.md](AGENTS.md).

**UNIX Philosophy**: Does one thing well. Composable with other tools via exit codes and stdout/stderr.

**Sensible Defaults**: Most operations require minimal configuration. Explicit when needed.

**Predictable**: Resources applied in manifest order. No hidden dependency resolution.

### Use Cases

- **Server provisioning**: Configure fresh systems
- **Development environments**: Consistent dev setups
- **CI/CD**: Apply configs in pipelines
- **Dotfiles management**: User environment setup
- **Homelab**: Manage personal infrastructure
- **Testing**: Spin up configured containers

---

## Contributing

Contributions are welcome! accord is designed for extensibility.

### How to Help

- **Add platform support**: See extensibility guide in [AGENTS.md](AGENTS.md)
- **Add resource types**: Follow resource implementation pattern
- **Improve documentation**: Examples, guides, man pages
- **Report bugs**: Open issues on GitHub
- **Write tests**: Expand test coverage

### Development

```bash
# Clone
git clone https://github.com/mateuszkwiatkowski/accord
cd accord

# Install the pinned Zig toolchain
mise install

# Build
zig build

# Run tests
zig build test

# Test on real VMs of every supported OS (Apple silicon Mac + QEMU)
scripts/vm-test.sh

# Install locally (binary and man pages)
sudo zig build -Doptimize=ReleaseSafe --prefix /usr/local install
```

Releases: see the checklist in [AGENTS.md](AGENTS.md) ("Releasing") and [CHANGELOG.md](CHANGELOG.md).

See [AGENTS.md](AGENTS.md) for architecture and development guide.

---

## License

MIT License - see [LICENSE](LICENSE) file.

---

## Resources

- **Repository**: https://github.com/mateuszkwiatkowski/accord
- **Issues**: https://github.com/mateuszkwiatkowski/accord/issues
- **Documentation**: See `doc/` directory for man pages
- **Architecture**: See [AGENTS.md](AGENTS.md) for detailed technical docs

---

**Built with Zig. Inspired by CFEngine. Designed for simplicity.**
