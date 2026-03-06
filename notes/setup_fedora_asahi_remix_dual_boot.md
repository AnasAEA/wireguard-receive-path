# Dual-Booting Fedora Asahi Remix on M1 Pro MacBook Pro

> **Why:** Need native Linux for io_uring development, kernel headers (`linux/fs.h`, `liburing`), `perf`, `bpftrace`, and benchmarking tools that don't exist on macOS.

---

## TL;DR Checklist

- [ ] Back up Mac with Time Machine
- [ ] Ensure ~100 GB free space
- [ ] Update macOS to latest
- [ ] Plug in power + stable internet
- [ ] Run installer from Terminal
- [ ] Shrink macOS partition (→ ~100 GB for Linux)
- [ ] Select Fedora Asahi Remix (KDE)
- [ ] Wait for download (~30 min)
- [ ] Shut down → Hold power → Boot into Fedora Asahi volume
- [ ] Authenticate to allow permissive security for Linux
- [ ] Complete Fedora first-boot setup (user, timezone, Wi-Fi)
- [ ] Reboot into Fedora → Done!

---

## Phase 1: Preparation and Backup

1. **Back Up Your Data**: Use Time Machine or another backup method. Partitioning always carries some risk.

2. **Free Up Space**: Need at least 100 GB free on internal drive. The installer shrinks macOS partition automatically. Empty Trash and remove large unnecessary files if needed.

3. **Update macOS** (Optional but Recommended): Updates firmware to newest version. Fedora Asahi installs a copy of Apple's firmware — latest firmware = better compatibility. FileVault can stay enabled.

4. **Connect Power and Internet**: Installer downloads several GB during setup. Fast connection recommended.

5. **Open Terminal on macOS**: `Applications > Utilities > Terminal`

---

## Phase 2: Installing via Terminal

### Step 1: Run the Installer

```bash
curl https://fedora-asahi-remix.org/install | sh
```

Enter macOS admin password when prompted. **Do NOT use Disk Utility manually** — let the Asahi installer handle everything.

### Step 2: Partition Size

- Installer shows current disk layout and asks how much to shrink macOS
- Target: Free ~100 GB for Fedora
- Example: If macOS is ~1 TB, shrink to ~900 GB → frees 100 GB
- Confirm the resize — macOS data stays intact

### Step 3: Select Fedora Asahi Remix

- Choose **Fedora Asahi Remix (KDE)** — the flagship desktop for Apple Silicon
- GNOME variant also available if preferred
- Allocate the full ~100 GB to Fedora
- Name the volume something recognizable like **"Fedora Asahi"**

### Step 4: Download and Install

- Downloads: Fedora ARM64 packages, Asahi kernel/drivers, Apple firmware copy
- Takes ~20-30 min depending on connection
- Creates 3 partitions in the free space:
  - ~2-3 GB APFS partition (Apple boot firmware)
  - ~<1 GB EFI partition (Linux bootloader)
  - ~97 GB ext4/btrfs (Linux root filesystem)

### Step 5: Shut Down (Don't Just Reboot!)

When installer says it's done, **shut down completely**. Do NOT just reboot.

---

## Phase 3: Finalizing Installation

### Step 1: Enter Startup Options

- Power OFF completely
- **Press and hold power button** until "Loading startup options…" appears
- You'll see: Macintosh HD + Fedora Asahi + Options

### Step 2: Boot Fedora Asahi (First Time)

- Click the **Fedora Asahi** icon
- First boot enters Recovery OS (by design — Apple security requirement)
- Authenticate with macOS admin credentials when prompted
- Installer automatically sets **Permissive Security** for Linux volume only
  - macOS stays in Full Security with SIP enabled
  - Linux gets the freedom it needs
  - Your Mac's macOS security is **unchanged**

### Step 3: Complete Fedora First-Boot Setup

- Set timezone/locale
- Create user account (username + password)
- Connect to Wi-Fi
- Follow all prompts until complete

### Step 4: Reboot into Fedora

- System reboots into Fedora Asahi Remix login screen
- Log in with credentials you just created
- Verify hardware: keyboard, trackpad, Wi-Fi, display

**Hardware support out of the box:** Display, GPU (OpenGL + Vulkan 1.4), Wi-Fi, Bluetooth, USB, touchpad, speakers, camera.

---

## Phase 4: Boot Selection

### How to Switch OS

| Action | How |
|--------|-----|
| Choose OS at boot | Shut down → Hold power button → Select OS |
| Set macOS as default | In startup menu: Hold **Option** while clicking macOS → Continue |
| Set Linux as default | In startup menu: Hold **Option** while clicking Fedora Asahi → Continue |
| From macOS GUI | System Settings > Startup Disk > Choose default |
| From Linux to boot menu | `systemctl reboot --firmware-setup` |

**Default after install:** Fedora Asahi Remix (change if desired).

### SIP Status

- **macOS:** SIP enabled, Full Security ✅
- **Linux:** Permissive Security (required for Linux to boot)
- Verify in macOS: `csrutil status` → should say "enabled"

---

## Phase 5: Post-Installation

### Update System

```bash
sudo dnf update -y
```

### Essential Packages for io_uring Work

```bash
# Kernel headers and development tools
sudo dnf install kernel-devel kernel-headers gcc make

# liburing (io_uring userspace library)
sudo dnf install liburing liburing-devel

# Performance tools
sudo dnf install perf bpftrace trace-cmd

# Benchmarking tools
sudo dnf install fio iperf3 sysbench

# General development
sudo dnf install git vim htop
```

### Display/HiDPI Settings

- KDE System Settings → Display → Adjust scaling for Retina display
- Trackpad: KDE System Settings → Trackpad → Enable tap-to-click

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Fedora not in startup menu | Shut down completely → Hold power again |
| Linux won't boot | Re-run installer or use Recovery > Startup Security Utility |
| Always boots to Fedora | Use startup picker to select macOS, or set default via Option+click |
| Want to remove Linux | Delete 3 Linux partitions → `diskutil apfs resizeContainer` to reclaim space |
| **Never delete** `Apple_APFS_Recovery` | That's macOS Recovery — essential! |

### Community Support

- Asahi Linux forums and Matrix chat
- Fedora Asahi SIG

---

## Disk Layout After Install

```
Internal SSD (~1 TB)
├── macOS APFS Container (~900 GB)
│   ├── Macintosh HD (macOS system)
│   └── Macintosh HD - Data (user data)
├── Apple_APFS_Recovery (macOS Recovery - DO NOT TOUCH)
├── Asahi APFS Container (~2-3 GB) — Apple firmware stub
├── EFI System Partition (~500 MB) — Linux bootloader
└── Linux Root Partition (~97 GB) — Fedora ext4/btrfs
```

---

*Saved: February 6, 2026*
*Source: Research AI guide for Fedora Asahi Remix installation*
