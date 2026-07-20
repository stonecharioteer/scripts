---
title: Laptop Hang RCA Notes
host: rog-x13-flow
initial_date: 2026-06-21
last_updated: 2026-07-20
os_stack: Linux Mint / Ubuntu
problem_kernel: 6.8.0-110-generic
current_mitigation_kernel: 6.8.0-90-generic
current_status:
  Retiring Linux/server use on this ASUS X13 Flow after repeated unclean resets and non-rebooting
  hard hangs across the tested Linux kernels, including another SSH-dead hard hang on 2026-07-20
  while booted into 6.8.0-110-generic with pcie_aspm=off. No preserved panic/oops/OOM/thermal/NVMe
  evidence was found; cumulative evidence points away from ordinary userspace load and toward an
  ASUS/AMD firmware-kernel power-management or interrupt-handling wedge. The laptop will be treated
  as a Windows gaming PC rather than a Linux host.
key_events:
  - date: 2026-06-21
    summary:
      Initial hard-hang investigation; SSH/display dead; hang monitoring and GPU mitigations added.
  - date: 2026-06-22
    summary:
      Headless/tent-mode screen-off workflow validated with backlight plus framebuffer blanking.
  - date: 2026-06-23
    summary:
      Kernel oops incident on 6.8.0-110-generic; SSH dead; console showed kmem_cache_alloc/anon_vma
      faults; switched GRUB default to 6.8.0-90-generic.
  - date: 2026-06-24
    summary:
      Confirmed more than 1 day stable on 6.8.0-90-generic; added screen keep-off service/timer.
  - date: 2026-07-02
    summary:
      Sudden unclean reboot on 6.8.0-90-generic; no oops/panic/OOM/thermal evidence preserved; added
      script to enable pstore archival, stronger panic-on-lockup sysctls, and timer dephasing.
  - date: 2026-07-07
    summary:
      Second sudden unclean reboot on 6.8.0-90-generic; previous boot stopped abruptly at 17:43:48,
      current boot began at 17:46:17; pstore empty; health snapshots showed no OOM, thermal, or disk
      fault, but Docker/GitHub runner churn was high near the final logs.
  - date: 2026-07-15/16
    summary:
      Hard hang rather than auto-reboot; previous boot stopped logging at 2026-07-15 17:48:01 and
      the machine was manually power-button restarted at 2026-07-16 21:33. Last health snapshots were
      healthy, with no OOM/thermal/NVMe/panic evidence; strongest clue was persistent AMD PCIe
      PME/runtime-PM noise plus irq/36-ELAN1201 in D state in the final snapshot.
  - date: 2026-07-20
    summary:
      Another SSH-dead hard hang, this time on 6.8.0-110-generic with pcie_aspm=off. Previous boot
      stopped logging abruptly at 10:12:06; hard reboot started at 11:50:32. Fish PATH changes were
      validated and ruled out. Last pre-hang health snapshot was quiet, with no OOM/thermal/NVMe/panic
      evidence. Decision: stop using this laptop as a Linux/server machine and repurpose it as a
      Windows gaming PC.
---

# Laptop Hang RCA Notes

Date: 2026-06-21 Host: `rog-x13-flow` OS/kernel observed: Linux Mint/Ubuntu stack,
`6.8.0-110-generic`

## Incident summary

Laptop was being used as a mostly headless/server machine. It became unreachable: GUI/display was
not responsive and SSH was also dead. A hard reboot occurred afterward.

`last -x` showed prior sessions ending with `crash`, indicating the system did not shut down
cleanly.

## Timeline

### 2026-06-21 initial hard-hang investigation

- Machine previously became unreachable: display/GUI unresponsive and SSH dead.
- Hard reboot was required.
- `last -x` indicated an unclean shutdown / `crash`.
- Initial suspects investigated: battery charge limit, Qtile user display services, hybrid
  NVIDIA/AMD graphics stack, display power management.
- Mitigations added: hang-health monitoring, persistent journald, SysRq, nouveau blacklist cleanup,
  NVIDIA dGPU disabled, and later `supergfxctl` integrated graphics mode.

### 2026-06-22 display/headless/tent-mode work

- Machine was running in `multi-user.target` with LightDM inactive.
- LightDM DPMS was not applicable in this mode.
- Direct backlight sysfs control alone set `bl_power=4`, `brightness=0`, `actual_brightness=0`, but
  did not visibly blank the panel.
- Adding framebuffer blanking via `/sys/class/graphics/fb0/blank` made the screen visibly turn off.
- Reusable helper added: `./screen.sh --off|--on|--status`.

### 2026-06-23 kernel oops / SSH-dead incident

- Previous boot was `Mon 2026-06-22 08:19:36 IST → Tue 2026-06-23 08:32:20 IST`.
- First recorded kernel oops occurred at `Tue 2026-06-23 06:03:00 IST` on kernel
  `6.8.0-110-generic`.
- Repeated kernel faults continued until at least `08:32:12 IST`.
- Physical photo taken at `/tmp/IMG_20260623_083225.jpg` showed kernel oops traces on the
  sleeping/woken console.
- SSH was unavailable even though the console could still show oops output.
- Hard reboot occurred; current boot started `Tue 2026-06-23 08:37:34 IST`.
- Root interpretation shifted from display/GPU sleep to kernel VM/slab memory corruption or kernel
  regression.
- Added `./setup-panic-on-oops.sh` to auto-reboot after future oopses.
- GRUB default was changed to boot older kernel `6.8.0-90-generic` using
  `./set-grub-kernel-6.8.0-90.sh`.
- Reboot confirmed the active kernel is now `6.8.0-90-generic`.

### 2026-06-24 stable rollback and screen keep-off follow-up

- Machine was checked after more than 1 day of uptime on `6.8.0-90-generic`.
- No recurrence of the previous bad signatures was found:
  - no `general protection fault`
  - no kernel oops/panic
  - no `kmem_cache_alloc` faults
  - no `anon_vma` faults
  - no OOM
  - no thermal spike
- Remaining warnings were limited to recurring PCIe/runtime-PM noise:
  - `workqueue: pm_runtime_work hogged CPU for >10000us`
  - `pcieport 0000:00:08.1: PME: Spurious native interrupt!`
- These power-management warnings map to AMD internal bridge `0000:00:08.1`, which leads to the
  Radeon 680M/iGPU-side devices and related AMD internal USB/audio/sensor devices.
- Interpretation: annoying but not currently harmful; do not change further while `6.8.0-90-generic`
  remains stable.
- Health logs showed stable battery and thermals:
  - battery range across logs: `58–59%`
  - charge threshold: `60%`
  - last ~24h CPU range: `36.9–42.6°C`
  - last ~24h GPU edge range: `36.0–45.0°C`
  - last ~24h NVMe range: `30.9–38.9°C`
- In text-console/headless mode, turning the screen off once is not always persistent. The panel can
  wake later due to console/framebuffer redraws or power-management activity.
- A keep-off timer was added as a mitigation so the panel is periodically forced back off while the
  laptop is being used in tent/headless mode.
- This is a Linux/headless-mode workaround, not a firmware-level fix. If the laptop is used
  interactively again, the keep-off behavior should be disabled first.

### 2026-07-02 sudden unclean reboot on `6.8.0-90-generic`

The laptop rebooted unexpectedly while still on the older mitigation kernel:

```text
Current kernel after reboot: 6.8.0-90-generic
Previous boot: Wed 2026-07-01 09:46:56 IST → Thu 2026-07-02 13:10:33 IST
Current boot:  Thu 2026-07-02 13:13:08 IST
```

`last -x` did not show a clean shutdown before this reboot. A prior SSH session ended with `crash`,
and the current boot logged:

```text
systemd-journald: system.journal corrupted or uncleanly shut down, renaming and replacing.
```

Unlike the earlier `6.8.0-110-generic` incident, the previous boot did not preserve a visible chain
of kernel oopses. Searches did not find:

```text
general protection fault
kernel oops/panic
kmem_cache_alloc fault
anon_vma fault
OOM
thermal critical event
clean shutdown target
explicit reboot request
```

The previous boot journal stopped abruptly around the recurring one-minute timers:

```text
Jul 02 13:10:33 systemd[1]: Starting hang-health-snapshot.service - Collect a health snapshot for debugging hangs...
Jul 02 13:10:33 systemd[1]: Starting x13-screen-off.service - Force ASUS X13 laptop panel off for headless/tent mode...
Jul 02 13:10:33 systemd[1]: x13-screen-off.service: Deactivated successfully.
```

The health snapshots immediately before the reboot looked normal:

```text
snapshot: 2026-07-02T13:09:31+05:30
uptime: 1 day, 3:24
load average: 0.09, 0.16, 0.17
memory: ~28 GiB available, swap 0B used
root disk: 45% used
AC online: 1
battery: 59%, status=Not charging, charge_control_end_threshold=60, power_now=0
CPU Tctl: ~40.2°C
AMD GPU edge: ~40.0°C
NVMe: ~31.9°C
NVIDIA driver: not running, expected
recent kernel warnings/errors in health snapshot: none
```

Interpretation: this was an unclean reboot/reset with no preserved final cause. It is not the same
signature as the `6.8.0-110-generic` VM/slab oops incident. The leading possibilities are:

1. firmware/hardware reset or power event,
2. kernel/firmware hang where final logs were not flushed,
3. panic/reboot path where pstore/kdump did not yet preserve evidence,
4. less likely: interaction/noise from one-minute health and screen keep-off timers running at the
   same second.

Mitigation/investigation script added:

```text
./setup-reboot-investigation.sh
```

It is intended to be run manually. It prepares evidence capture for the next event by:

- setting diagnostic panic sysctls:
  - `kernel.panic = 30`
  - `kernel.panic_on_oops = 1`
  - `kernel.softlockup_panic = 1`
  - `kernel.hung_task_panic = 1`
- mounting/checking `/sys/fs/pstore` when firmware exposes it,
- installing `archive-pstore.service` to copy pstore records after boot into
  `/var/log/pstore-archive/`,
- de-phasing `x13-screen-off.timer` so it does not fire at exactly the same cadence/second as
  `hang-health-snapshot.timer`,
- optionally installing kdump tooling with `INSTALL_KDUMP=1 ./setup-reboot-investigation.sh`.

After any future unexpected reboot, check:

```bash
sudo find /var/log/pstore-archive -maxdepth 2 -type f -print
sudo grep -R . /var/log/pstore-archive /sys/fs/pstore 2>/dev/null | less
journalctl -b -1 -k --no-pager | tail -300
last -x | head -30
```

### 2026-07-07 second sudden unclean reboot on `6.8.0-90-generic`

The laptop rebooted unexpectedly again while still on the rollback kernel:

```text
Current kernel after reboot: 6.8.0-90-generic
Previous boot: Thu 2026-07-02 13:13:08 IST → Tue 2026-07-07 17:43:48 IST
Current boot:  Tue 2026-07-07 17:46:17 IST
Observed uptime after reconnect: ~1-2 minutes
```

The reboot was unclean. The current boot logged journal corruption/replacement:

```text
systemd-journald[444]: File /var/log/journal/.../system.journal corrupted or uncleanly shut down, renaming and replacing.
```

The previous boot journal ended abruptly at `17:43:48`; there was no clean shutdown/reboot sequence
before the new boot at `17:46:17`. Searches did not find a preserved final cause:

```text
No kernel panic/oops in the final previous-boot journal.
No OOM/out-of-memory evidence.
No thermal critical event.
No NVMe I/O errors, media errors, or SMART critical warnings.
No pstore files under /sys/fs/pstore or /var/log/pstore-archive.
```

The last previous-boot log entries were dominated by Docker/container activity and GitHub Actions
runner conflicts:

```text
Jul 07 17:43:46 dockerd: healthcheck failed fatally: ... only one connection allowed
Jul 07 17:43:46 systemd: Started docker-...scope
Jul 07 17:43:46 kernel: br-f359ba95c655: port ... entered forwarding state
Jul 07 17:43:48 avahi-daemon: Registering new address record for ... on veth...
Jul 07 17:43:48 systemd: var-lib-docker-overlay2-...-init-merged.mount: Deactivated successfully.
```

The health snapshots immediately before the reboot did not show classic resource exhaustion:

```text
snapshot: 2026-07-07T17:43:34+05:30
uptime: 5 days, 4:31
load average: 4.61, 1.74, 0.92
memory: ~25 GiB available, swap ~512 KiB used
root disk: 53% used
AC online: 1
battery: 57%, status=Charging, threshold=60, power_now≈7.3 W
thermal_zone0: 68°C
thermal_zone1: 20°C
thermal_zone2/iwlwifi: 50°C
```

The next health snapshot was after reboot:

```text
snapshot: 2026-07-07T17:46:47+05:30
uptime: 2 min
memory: ~28 GiB available, swap 0B used
battery: 59%, status=Discharging
thermal_zone0: 68°C
thermal_zone2/iwlwifi: 52°C
```

Daily NVMe health logging showed the disk itself was healthy near the event:

```text
SMART overall-health self-assessment: PASSED
critical_warning: 0
media_errors: 0
num_err_log_entries: 0
temperature: 33°C
percentage_used: 2%
```

Interpretation: this matches the 2026-07-02 pattern more than the 2026-06-23
`6.8.0-110-generic` oops pattern. It appears to be a sudden reset/firmware-level reboot/kernel
hang where logs were not flushed, not an orderly shutdown and not an observed Linux OOM/thermal/NVMe
failure. Docker/GitHub-runner churn was the most prominent workload near the final logs, but it is
not proven as the root cause; it may only be the workload that made a latent kernel/firmware/power
bug easier to trigger.

Next investigation focus after this recurrence:

1. Preserve pstore/kdump status immediately after every future reboot; July 7 had no pstore files.
2. Fix known system noise so future evidence is cleaner:
   - GitHub Actions runner duplicate-session/service failures.
   - `x13-screen-off.timer.d/10-dephase.conf` parse warning.
3. Consider testing PCIe/power-management mitigation such as `pcie_aspm=off` if sudden resets recur.
4. Consider temporarily stopping Docker/GitHub runners to see whether idle/server uptime improves.
5. If events continue on `6.8.0-90-generic`, escalate from "bad kernel 6.8.0-110" to broader ASUS
   X13 Flow firmware/ACPI/PCIe/power-management or hardware instability investigation.

### 2026-07-15/16 hard hang requiring power button

This incident differed from the July 2/7 sudden resets: the machine did not auto-reboot. It stopped
responding to SSH and had to be recovered with the power button. The previous boot was:

```text
Previous boot: Sat 2026-07-11 14:14:24 IST → Wed 2026-07-15 17:48:01 IST
Current boot:  Thu 2026-07-16 21:33:07 IST
Current kernel: 6.8.0-90-generic
```

The final previous-boot journal entries were normal periodic jobs. There was no clean shutdown path,
and the next boot showed an unclean journal replacement:

```text
Jul 15 17:47:53 systemd: Finished hang-health-snapshot.service
Jul 15 17:48:01 CRON: battery-cycles collect ... session closed
Jul 16 21:33:07 systemd-journald: system.journal corrupted or uncleanly shut down, renaming and replacing.
```

Searches of the previous boot did not find a preserved kernel panic, oops, lockup report, RCU stall,
hung-task report, OOM kill, thermal critical event, NVMe I/O error, or pstore record. `archive-pstore`
ran successfully after boot, but `/sys/fs/pstore` and `/var/log/pstore-archive` had no crash files.
Panic-on-oops/softlockup/hung-task sysctls were still enabled, which makes an unlogged firmware/driver
hang more likely than a clean kernel panic path.

The health snapshots immediately before logging stopped were normal:

```text
snapshot: 2026-07-15T17:47:53+05:30
uptime: 4 days, 3:35
load average: 0.22, 0.23, 0.28
memory: ~26 GiB available, swap 0B used
root disk: 52% used
AC online: 1
battery: 59%, status=Not charging, threshold=60, power_now=0
CPU Tctl: ~42.8°C
AMD GPU edge: ~44°C
NVMe: ~34.9°C
recent kernel warnings/errors in health snapshot: none
```

The strongest clue in the final snapshots was not resource pressure but low-level device/PM activity:

```text
last-hour kernel warnings: repeated pcieport 0000:00:08.1: PME: Spurious native interrupt!
earlier: workqueue: pm_runtime_work hogged CPU for >10000us 4096 times
final top CPU sample: kworker/*-pm and irq/36-ELAN1201 present; irq/36-ELAN1201 was in D state at 17:46:48
current boot IRQ mapping: IRQ 36 = amd_gpio 8 ELAN1201:00; IRQ 35 = amd_gpio 115 ELAN9008:00
current boot has i2c_hid_acpi bound to i2c-ELAN1201:00 and i2c-ELAN9008:00
```

Interpretation: the hang cause is still not proven, but this incident now points more strongly to an
ASUS/AMD firmware-kernel device power-management or interrupt-handling wedge than to Docker/GitHub
runner load, OOM, thermals, storage, or the old `6.8.0-110-generic` VM/slab oops. The recurring AMD
PCIe PME/runtime-PM warnings remain the broad platform-level suspect. The new per-incident clue is
the ELAN I2C HID path (`ELAN1201:00` via `amd_gpio`) appearing in uninterruptible sleep in the final
health sample; that may be a symptom of the same PM/interrupt wedge rather than the root device.

Recommended next mitigation if this recurs or if uptime matters more than power savings:

1. Test a PCIe/runtime-PM mitigation boot such as `pcie_aspm=off`.
2. Consider disabling runtime PM for the noisy AMD internal PCIe bridge / related devices if a
   narrower sysfs mitigation is preferred.
3. If the laptop is headless/tent-mode only, consider unbinding or disabling unused ELAN I2C HID
   devices as a controlled test, especially if `irq/36-ELAN1201` or `i2c_hid_acpi` appears in D state
   again before a hang.
4. Keep pstore/kdump capture enabled; no crash evidence was available for this event.
5. Continue treating Docker/GitHub runners as workload/noise, not the leading root cause for this
   event, because the final load/memory/thermal data were quiet.

### 2026-07-20 repeat SSH-dead hard hang and Linux retirement decision

Another non-rebooting hard hang occurred while the machine was still being used as a Linux/server
host. SSH refused or stopped accepting connections from the client side, and the machine required a
hard reboot. The observed boot history was:

```text
Previous boot: Fri 2026-07-17 16:05:02 IST → Mon 2026-07-20 10:12:06 IST
Hard reboot / current boot: Mon 2026-07-20 11:50:32 IST
Kernel before hang: 6.8.0-110-generic with pcie_aspm=off
Kernel after reboot:  6.8.0-90-generic
```

`last -x` showed the active SSH sessions from `192.168.100.234` ending with `crash`, not a clean
logout. The previous boot journal ended abruptly at `10:12:06`; the next boot began at `11:50:32`
and journald reported the expected unclean-shutdown journal replacement. There was no orderly
shutdown, reboot target, or sshd-side refusal sequence preserved. The SSH service was healthy after
reboot and accepted the same public key at `11:51:02`, so the client-side "connection refused"
behavior is best interpreted as the host/network/sshd no longer servicing connections during the
wedge, not as an SSH configuration failure.

The last pre-hang health snapshot was quiet:

```text
snapshot: 2026-07-20T10:12:06+05:30
uptime: 2 days, 18:08
load average: 0.17, 0.16, 0.11
memory: ~27 GiB available, swap 0B used
root disk: 53% used, ~175 GiB free
AC online: 1
battery: 59%, status=Not charging, threshold=60, power_now=0
CPU Tctl: ~51.9°C
AMD GPU edge: ~52°C
NVMe: ~35.9°C
recent kernel warnings/errors in health snapshot: none
```

Searches around the previous boot did not find a preserved OOM, thermal critical event, NVMe I/O
error, panic/oops, lockup, watchdog, or pstore crash record. This matches the July 15/16 hard-hang
pattern more than a normal userspace failure: the machine can stop logging and stop serving SSH while
resource telemetry still looks healthy shortly before the event.

The Fish PATH edit made shortly before the report was checked separately and ruled out as the cause:

```text
fish -n ~/.config/fish/config.fish          # passed
timeout 8 fish -lc 'echo fish-ok ...'       # passed; scripts path present
timeout 10 fish -i -c 'echo interactive...' # passed
```

RCA conclusion after this recurrence: the exact device/driver fault is still not proven, but the
repeated pattern is no longer worth treating as a simple script, SSH, Docker, battery, thermal, disk,
or shell-configuration issue. The latest event also happened despite `pcie_aspm=off`, so that broad
PCIe ASPM mitigation was insufficient. Across incidents, the strongest remaining explanation is ASUS
X13 Flow Linux platform instability: an ASUS/AMD firmware-kernel power-management, PCIe/runtime-PM,
I2C HID, Wi-Fi/ACPI, or interrupt-handling wedge that can leave the system alive enough to preserve
no crash record but dead enough to require a hard reboot.

Operational decision: stop investing in this laptop as a Linux/headless/server host. Repurpose it as
a Windows gaming PC and move Linux/server workloads elsewhere.

## Initial hypothesis checks

### Battery / charge limit

Battery was capped at 60%:

```text
charge_control_end_threshold=60
capacity≈59
status=Not charging / Discharging
AC0 online=1
```

Battery collector logs showed battery reached ~59% and stayed there. No low-battery/critical-battery
evidence was found.

Conclusion: battery charge limit is unlikely to be the direct cause.

### Qtile / user display services

Found user services running from Qtile setup even outside useful GUI context:

- `auto-rotate.service`
- `monitor-manager.service`

They were enabled under user `default.target`, so they could run on user systemd startup / SSH
login, not only Qtile login.

Observed repeated failures:

```text
auto-rotate.service: restart counter 900+
monitor-manager.sh: Invalid MIT-MAGIC-COOKIE-1 key
monitor-manager.sh: Can't open display :0
```

These were disabled as persistent user services. Qtile still starts them via
`~/.config/qtile/autostart.sh`, so they should run only when Qtile starts.

Conclusion: noisy/misconfigured, but since SSH was dead during the incident, this is probably not
the whole root cause.

### GPU / display stack

System has hybrid GPU:

```text
NVIDIA RTX 3050 Ti Laptop GPU
AMD Radeon 680M iGPU
```

Prior logs showed NVIDIA PCIe/AER warnings:

```text
nvidia 0000:01:00.0: PCIe Bus Error: severity=Correctable
BadTLP
RxErr
```

Because this machine is used for CPU/RAM/storage and not GPU, NVIDIA dGPU was disabled through PRIME
integrated mode.

Current post-reboot status:

```text
prime-select query => intel
nvidia-smi => fails because NVIDIA driver is not running
```

Note: `prime-select intel` means integrated-GPU mode even though this is an AMD iGPU system.

Conclusion: GPU/display power management or NVIDIA hybrid stack remains a plausible cause,
especially because hang happened after display sleep and SSH died.

## Changes made

### User display services

Disabled systemd user services from starting automatically:

```bash
systemctl --user disable --now auto-rotate.service monitor-manager.service
```

`auto-rotate.service` was restored as a file but left disabled. Qtile autostart still runs:

```bash
systemctl --user start auto-rotate.service
~/.config/qtile/install/monitor-manager/monitor-manager.sh &
```

### NVIDIA dGPU disabled

Script created:

```text
./disable-nvidia-dgpu.sh
```

It runs:

```bash
sudo prime-select intel
sudo systemctl disable --now nvidia-persistenced.service
```

A reboot is required after running it.

### Nouveau blacklist fixed

`/etc/modprobe.d/blacklist-nouveau.conf` had stray `EOF` line. Fixed with:

```text
blacklist nouveau
options nouveau modeset=0
```

Script created:

```text
./fix-blacklist-nouveau.sh
```

It also runs:

```bash
sudo update-initramfs -u
```

### Hang monitoring installed

Script created and run:

```text
./setup-hang-monitoring.sh
```

It installed:

```text
/usr/local/sbin/hang-health-snapshot
/etc/systemd/system/hang-health-snapshot.service
/etc/systemd/system/hang-health-snapshot.timer
```

Timer is enabled and logs every minute to:

```text
/var/log/hang-health.log
```

It records:

- uptime/load
- RAM/swap
- disk usage
- AC/battery state
- thermal zones
- `sensors` output
- NVIDIA state if available
- top CPU/memory processes
- recent kernel warnings/errors

Persistent journald storage was enabled via `/var/log/journal`.

SysRq was enabled:

```text
/etc/sysctl.d/99-sysrq.conf
kernel.sysrq = 1
```

## Current healthy baseline after reboot

After clean reboot at ~15:31:

```text
hang-health-snapshot.timer: active
prime-select query: intel
nvidia-smi: NVIDIA driver not running
RAM: ~29 GiB available
Swap: unused
Disk /: ~36% used
NVMe: ~34°C
CPU: ~49-59°C
AC0 online=1
Battery: ~59%, threshold=60
Recent kernel warnings/errors: none
```

Later update after installing `supergfxctl` and switching graphics mode:

```text
supergfxctl -g: Integrated
prime-select query: intel
nvidia-smi: NVIDIA driver not running
/sys/class/backlight/amdgpu_bl1 exists
/sys/class/drm/card1-eDP-1 connected/enabled
```

This fixed the earlier bad display-routing state where LightDM/Xorg was using a simple framebuffer
and no real `/sys/class/backlight` device existed. After `sudo supergfxctl -m Integrated` and
reboot, the login-screen display timeout worked: the screen/backlight turned off and pressing a
laptop key woke it.

Fan/performance controls available through kernel platform profiles:

```text
/sys/firmware/acpi/platform_profile_choices: quiet balanced performance
/sys/firmware/acpi/platform_profile: balanced
```

Useful commands:

```bash
cat /sys/firmware/acpi/platform_profile_choices
cat /sys/firmware/acpi/platform_profile
echo quiet | sudo tee /sys/firmware/acpi/platform_profile
echo balanced | sudo tee /sys/firmware/acpi/platform_profile
echo performance | sudo tee /sys/firmware/acpi/platform_profile
sensors
```

TTY/headless screen-off notes after disabling LightDM:

- Physical console is usually `tty1`; SSH sessions are `pts/*`.
- `setterm --blank/--powerdown` did not reliably blank/power off the laptop panel.
- Kernel consoleblank was already set to `60`, but that did not visibly power off the panel.
- Direct backlight sysfs control works, but may have a delayed visible effect.

Observed working manual screen-off method in text-console/headless mode:

```bash
echo 4 | sudo tee /sys/class/backlight/amdgpu_bl1/bl_power
echo 0 | sudo tee /sys/class/backlight/amdgpu_bl1/brightness
echo 1 | sudo tee /sys/class/graphics/fb0/blank
```

The backlight-only commands set `bl_power=4`, `brightness=0`, and `actual_brightness=0`, but the
panel still appeared active. Adding framebuffer blanking via `/sys/class/graphics/fb0/blank` made
`--off` visibly work.

Restore from SSH:

```bash
echo 0 | sudo tee /sys/class/graphics/fb0/blank
echo 0 | sudo tee /sys/class/backlight/amdgpu_bl1/bl_power
echo 255 | sudo tee /sys/class/backlight/amdgpu_bl1/brightness
```

Reusable helper added:

```bash
~/.config/qtile/laptop/x13-flow/screen.sh --off
~/.config/qtile/laptop/x13-flow/screen.sh --on
~/.config/qtile/laptop/x13-flow/screen.sh --status
```

State when off should look like:

```text
brightness=0
actual_brightness=0
bl_power=4
fb0 blank=1
```

Unlike LightDM/DPMS, a laptop keypress may not restore this sysfs/framebuffer state; SSH restore
with `screen.sh --on` is safest. This works for now for tent/headless mode.

## 2026-06-23 kernel oops / SSH-dead incident

The machine became unreachable over SSH again and required a hard reboot. The screen had been
sleeping/blanked, but pressing a laptop key showed kernel oops traces on the physical console.

Photo evidence from `/tmp/IMG_20260623_083225.jpg` matched the journal logs. The visible console
showed faults in:

```text
RIP: kmem_cache_alloc+0xd3/0x350
Call Trace:
  anon_vma_clone
  anon_vma_fork
  dup_mmap
  dup_mm
  copy_process
  kernel_clone
  __do_sys_clone
```

and also:

```text
RIP: anon_vma_interval_tree_insert+0x40/0xe0
```

Journal evidence from previous boot:

```text
Previous boot: Mon 2026-06-22 08:19:36 IST → Tue 2026-06-23 08:32:20 IST
Current boot:  Tue 2026-06-23 08:37:34 IST
Kernel: 6.8.0-110-generic
First fault: Jun 23 06:03:00, Comm: sh, RIP: anon_vma_interval_tree_insert
Repeated faults: 90 total by Jun 23 08:32:12, often Comm: cron/runc/containerd-shim, RIP: kmem_cache_alloc
```

Preserved log evidence from `last -x` and `journalctl --list-boots`:

```text
last -x:
  reboot   system boot 6.8.0-110-generic Mon Jun 22 08:19   still running
  runlevel (to lvl 3) 6.8.0-110-generic Mon Jun 22 08:19 - 08:37 (1+00:17)
  reboot   system boot 6.8.0-110-generic Tue Jun 23 08:37   still running

journalctl --list-boots:
  -1 00d5ad1b6c7a44ae869050145d443ef2 Mon 2026-06-22 08:19:36 IST Tue 2026-06-23 08:32:20 IST
   0 f686260ec1814c4cb5ab7e42add335fb Tue 2026-06-23 08:37:34 IST Tue 2026-06-23 08:38:43 IST

post-reboot journal note:
  systemd-journald: system.journal corrupted or uncleanly shut down, renaming and replacing.
```

First-oops context from previous boot kernel log:

```text
Jun 22 08:23:13 workqueue: pm_runtime_work hogged CPU for >10000us 4 times
Jun 22 08:27:43 workqueue: pm_runtime_work hogged CPU for >10000us 8 times
Jun 22 08:36:23 workqueue: pm_runtime_work hogged CPU for >10000us 16 times
Jun 22 08:53:43 workqueue: pm_runtime_work hogged CPU for >10000us 32 times
Jun 22 09:28:53 workqueue: pm_runtime_work hogged CPU for >10000us 64 times
Jun 22 10:39:52 workqueue: pm_runtime_work hogged CPU for >10000us 128 times
Jun 22 13:00:23 workqueue: pm_runtime_work hogged CPU for >10000us 256 times
Jun 22 16:04:01 pcieport 0000:00:08.1: PME: Spurious native interrupt!
Jun 22 17:42:01 workqueue: pm_runtime_work hogged CPU for >10000us 512 times
Jun 23 03:04:33 workqueue: pm_runtime_work hogged CPU for >10000us 1024 times
Jun 23 03:42:20 pcieport 0000:00:08.1: PME: Spurious native interrupt!
Jun 23 05:29:01 pcieport 0000:00:08.1: PME: Spurious native interrupt!
Jun 23 06:03:00 general protection fault, probably for non-canonical address 0x8d6c54288c526de0: 0000 [#1] PREEMPT SMP NOPTI
Jun 23 06:03:00 CPU: 13 PID: 1401821 Comm: sh Not tainted 6.8.0-110-generic #110-Ubuntu
Jun 23 06:03:00 RIP: 0010:anon_vma_interval_tree_insert+0x40/0xe0
Jun 23 06:03:00 Call Trace: anon_vma_fork → dup_mmap → dup_mm → copy_process → kernel_clone → __do_sys_clone
Jun 23 06:03:01 general protection fault, probably for non-canonical address 0x6293dec4c5fbb468: 0000 [#2] PREEMPT SMP NOPTI
Jun 23 06:03:01 CPU: 13 PID: 1401826 Comm: cron Tainted: G      D            6.8.0-110-generic #110-Ubuntu
Jun 23 06:03:01 RIP: 0010:kmem_cache_alloc+0xd3/0x350
```

Fault progression summary:

```text
Oops count: 90
First: Jun 23 06:03:00, Comm: sh, RIP: anon_vma_interval_tree_insert
Second: Jun 23 06:03:01, Comm: cron, RIP: kmem_cache_alloc
Later examples:
  Jun 23 07:55:15 Comm: runc / runc:[2:INIT]
  Jun 23 08:14:41 Comm: containerd-shim
  Jun 23 08:27:42 Comm: runc:[1:CHILD]
Last: Jun 23 08:32:12, Comm: runc, RIP: kmem_cache_alloc
Common repeated bad address: 0x6293dec4c5fbb468
Common CPU in traces: CPU 13
```

Cron/systemd activity immediately before first oops:

```text
Jun 23 06:00:01 cron ran battery-monitor.sh, battery-cycles collect, redshift/gamma.sh
Jun 23 06:00:22 systemd ran fwupd-refresh and hang-health-snapshot
Jun 23 06:00:53 systemd ran battery-charge-limit.service
Jun 23 06:01:01 cron ran battery-cycles collect
Jun 23 06:01:23 systemd ran hang-health-snapshot
Jun 23 06:01:53 user systemd ran battery-logger.service
Jun 23 06:02:01 cron ran battery-cycles collect
Jun 23 06:02:33 systemd ran hang-health-snapshot
Jun 23 06:03:00 first kernel oops in sh/fork path
Jun 23 06:03:43 hang-health-snapshot started but resulting snapshot was incomplete
```

Last complete health snapshots before the first oops were normal:

```text
snapshot 2026-06-23T06:02:33+05:30
uptime: 21:44
load average: 0.12, 0.17, 0.14
memory: 30Gi total, 2.5Gi used, 18Gi free, 28Gi available
swap: 2.0Gi total, 0B used
root disk: 384G size, 133G used, 232G available, 37% used
AC0: online=1
BAT0: status=Not charging, capacity=58, charge_control_end_threshold=60, power_now=0
thermal zones: acpitz 38C/20C, iwlwifi 37C
amdgpu edge: +39.0°C, PPT 15.22 W
CPU k10temp Tctl: +39.0°C
NVMe composite: +31.9°C
asus fans: cpu_fan=0 RPM, gpu_fan=0 RPM
NVIDIA: nvidia-smi failed because NVIDIA driver was not running
recent kernel warnings/errors in health snapshot: none
```

The final pre-reboot health log marker was:

```text
===== snapshot 2026-06-23T06:03:43+05:30 =====
```

That snapshot was truncated/incomplete after `-- top cpu --`, consistent with the machine already
being damaged by the first oopses. The next health snapshot was after hard reboot:

```text
===== snapshot 2026-06-23T08:38:01+05:30 =====
uptime: 2 min
```

Negative evidence preserved from logs:

```text
No OOM or swap exhaustion before first oops.
No thermal spike before first oops.
No NVIDIA driver running; nvidia-smi failed as expected.
No clear MCE/EDAC/hardware-error report was found in the journal.
Only one Docker container was observed after reboot: linuxserver/syncthing.
```

Interpretation: not a display-sleep issue, not OOM, not thermal, and not likely NVIDIA. The kernel
was alive enough to print oops traces and wake the panel, but userspace/networking was broken enough
that SSH was unavailable. This points to kernel memory corruption / kernel bug / RAM instability.
Because the repeated failures happened in fork/exec/VM/slab paths, ordinary cron, shell,
Docker/runc, and sshd activity could fail after the first corruption.

Mitigations added:

```text
./setup-panic-on-oops.sh
```

This installs:

```text
/etc/sysctl.d/99-panic-on-oops.conf
kernel.panic_on_oops = 1
kernel.panic = 30
```

Purpose: if a future kernel oops occurs, reboot automatically after ~30 seconds instead of staying
SSH-dead indefinitely.

Recommended kernel test:

1. Reboot.
2. In GRUB, choose:

```text
Advanced options for Linux Mint/Ubuntu
→ Linux ... 6.8.0-90-generic
```

3. Do not choose recovery mode.
4. Verify after boot:

```bash
uname -r
```

Expected:

```text
6.8.0-90-generic
```

If `6.8.0-90-generic` is stable, suspect a `6.8.0-110-generic` regression. If the issue recurs
across older kernels, suspect RAM/hardware and run an overnight memtest.

## If it hangs/reboots again

After reboot, collect:

```bash
last -x | head -30
journalctl -b -1 -p warning..alert --no-pager
journalctl -b -1 -k --no-pager | tail -300
tail -500 /var/log/hang-health.log
prime-select query
lsmod | grep '^nvidia' || true
nvidia-smi || true
```

Also check whether the previous shutdown was clean:

```bash
last -x | head
```

Interpretation:

- If `last` says `crash`, previous boot died uncleanly.
- If `/var/log/hang-health.log` stops abruptly without thermal/OOM warnings, suspect
  kernel/hardware/firmware hang.
- If temps spike before stop, suspect thermal/power.
- If memory/swap exhaustion appears, suspect workload/OOM.
- If NVIDIA modules reappear or GPU/AER messages return, suspect dGPU/hybrid graphics.
- If AC goes offline or battery drains rapidly, suspect charger/EC/power path.

## Next mitigation ideas if hang recurs

1. Disable display manager/GUI entirely when using as server:

```bash
sudo systemctl set-default multi-user.target
sudo systemctl disable --now lightdm
```

2. Disable DPMS/display sleep from Qtile autostart as a test.

3. Add kernel boot params to reduce PCIe power-management issues, e.g. test-only:

```text
pcie_aspm=off
```

4. Check firmware/BIOS updates for ASUS ROG X13 Flow.

5. Boot/test older installed kernel `6.8.0-90-generic` from GRUB advanced options; avoid
   `6.8.0-110-generic` until proven safe.

6. If the issue recurs across kernels, run overnight memtest / hardware diagnostics.

7. Consider a newer HWE/OEM kernel if GPU/ACPI hangs continue or if older-kernel rollback is not
   sufficient.

## Final Linux issue summary

The laptop was not reliable as a Linux workstation or headless/server host. Across the investigation,
the recurring issues were:

- Full-system hangs where both the local UI/display path and SSH became unavailable, requiring a hard
  reboot or power-button recovery.
- A clear `6.8.0-110-generic` kernel oops incident with repeated VM/slab/fork-exec related faults
  (`kmem_cache_alloc` / `anon_vma` style traces), leaving the machine SSH-dead.
- Sudden unclean reboots on the rollback `6.8.0-90-generic` kernel with no clean shutdown path and no
  preserved final panic/oops cause.
- Later non-rebooting hard hangs on Linux, including the July 15/16 and July 20 events, where health
  snapshots showed normal memory, swap, disk, battery, and thermals shortly before logging stopped.
- Repeated journal corruption/replacement after recovery, consistent with forced or unclean shutdowns.
- Persistent AMD/ASUS platform noise: PCIe PME spurious interrupts, runtime-PM workqueue warnings,
  and suspected low-level power-management or interrupt-handling wedges.
- ELAN I2C HID / `amd_gpio` involvement in the final July 15/16 evidence (`irq/36-ELAN1201` in D
  state), likely another symptom of the platform/interrupt wedge.
- Headless/tent-mode display management problems: backlight control alone was insufficient, requiring
  framebuffer blanking and a periodic keep-off timer.
- Hybrid graphics/NVIDIA integration remained brittle enough that the dGPU was disabled/avoided during
  troubleshooting, though the later failures did not point primarily to NVIDIA.
- Diagnostic capture was poor for the worst failures: pstore did not preserve useful crash records,
  and the system often stopped logging before the actual root fault became visible.
- Workload noise from Docker, GitHub Actions runners, cron jobs, and health timers made logs busier,
  but the strongest evidence did not support these as the primary cause.
- A broad PCIe ASPM mitigation (`pcie_aspm=off`) was insufficient; the July 20 hang occurred while it
  was present on the kernel command line.

### Temperature distribution across captured health data

The raw health log snapshot used for this table is committed as:

```text
laptop/x13-flow/provenance/hang-health-2026-07-20.log.zst
raw snapshot sha256: 0941eba116c446bc1a1238b4eaacddf6ed570ad1b857b29bc8385b08fdc7f907
zstd artifact sha256: 4761f761dcd8940fa54e40734bee75b94c0248459b5ad1137fb68e37c51a2928
```

| Sensor | Samples | Min °C | P25 °C | P50 °C | P75 °C | P90 °C | P95 °C | P99 °C | Max °C |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| CPU Tctl | 36596 | 33.4 | 40.1 | 41.6 | 43.8 | 51.9 | 53.1 | 67.2 | 93.9 |
| thermal_zone0 | 36596 | 33.0 | 39.0 | 41.0 | 43.0 | 51.0 | 52.0 | 67.0 | 94.0 |
| AMD GPU edge | 36596 | 32.0 | 40.0 | 41.0 | 43.0 | 51.0 | 52.0 | 56.0 | 77.0 |
| NVMe Composite | 36596 | 28.9 | 31.9 | 31.9 | 32.9 | 36.9 | 36.9 | 38.9 | 51.9 |
| iwlwifi | 36596 | 34.0 | 38.0 | 39.0 | 42.0 | 50.0 | 51.0 | 54.0 | 66.0 |

Final decision: Linux on this ASUS X13 Flow is not worth further time for this use case. Treat the
machine as a Windows gaming PC and move Linux/server workloads to more stable hardware.
