
## Runtime Architecture

### Partition Layout

The device image has three partitions:

1. `/boot` — FAT, kernel and bootloader config
2. `imgpart` — ext4, holds squashfs image files (`volumio_current.sqsh`, `volumio_fallback.sqsh`, kernel tarballs)
3. `datapart` — ext4, persistent writable user data

### Filesystem at Runtime

The OS runs from a read-only squashfs image mounted via an overlayfs union:

- `lowerdir` — squashfs mounted read-only at `/static`
- `upperdir` — datapart's `dyn/` directory (writable, copy-on-write)
- Union root (`/`) — the combined view presented to the OS

Any file written to `/` at runtime is stored in the overlayfs upper dir on the datapart and persists across reboots.

### Backend Repository (`VOL_BE_REPO`)

During the build, `VOL_BE_REPO` is cloned into `build/<suite>/<arch>/root/volumio/` and packed into the squashfs. On the running device it is available at `/volumio`.

### Persistent Data (`/data`)

`/data` is the designated location for persistent application and user data. It lives in the squashfs as an empty directory, so all runtime writes land cleanly in the overlayfs upper dir and survive OTA updates.

Key paths:

- `/data/INTERNAL` — internal music storage (symlinked from `/mnt/INTERNAL`, exposed via Samba, fed to MPD)
- `/data/` — Volumio backend config/database files

### OTA Update Flow

1. The running backend downloads a `.fir` update bundle to `/boot`.
2. On next boot, initramfs detects the bundle and calls `volumio-init-updater`.
3. The updater extracts a new squashfs to `imgpart` as `volumio_current.sqsh` (and optionally a new kernel tarball flagged by `/boot/kernel_update`).
4. If a kernel update is included, `process_kernel_update()` unpacks the tarball to `/boot` and reboots.
5. Rollback: if `/boot/update_process` exists on the following boot (indicating the previous update did not complete), initramfs restores `volumio_fallback.sqsh` → `volumio_current.sqsh` and `kernel_fallback.tar` → `kernel_current.tar`.

The datapart (user data and overlayfs upper dir) is preserved across all updates.

## Development Notes

### Applying Changes on a Running Device

- **JS files** — changes to files under `/volumio` take effect immediately (Node.js `require` cache aside).
- **EJS templates** — the Volumio service runs with `NODE_ENV=production`, which enables Express view caching. Changes to `.ejs` files require a service restart to take effect:

```
systemctl restart volumio
```
