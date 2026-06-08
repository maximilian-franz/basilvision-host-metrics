# host-metrics

Push host system metrics (CPU load, memory, disk, temperature, uptime, systemd unit status) to a remote API on a schedule.

This project includes:
- A metrics push script: [push_metrics.sh](push_metrics.sh)
- A systemd service: [basilvision-push-metrics.service](basilvision-push-metrics.service)
- A systemd timer: [basilvision-push-metrics.timer](basilvision-push-metrics.timer)
- Interactive installer: [install.sh](install.sh)

## How It Works

1. The systemd timer triggers every 5 minutes (after an initial 2-minute delay on boot).
2. `push_metrics.sh` collects the following metrics from the host:
   - 1-minute load average (`/proc/loadavg`)
   - Memory used percentage (`/proc/meminfo`)
   - CPU temperature (`/sys/class/thermal/thermal_zone0/temp` or `vcgencmd`)
   - Uptime in seconds (`/proc/uptime`)
   - Root disk used percentage (`df -P /`)
   - Active/failed status for `motion.service`, `motion-snapshot.service`, and `motion-snapshot.timer`
3. Metrics are assembled into a JSON payload and sent via HTTP POST to the configured API endpoint.

## Requirements

- Linux host with systemd
- Root access for installation
- `curl` for HTTP transport
- Internet access to the metrics API endpoint

The installer currently supports apt-based systems (for example Ubuntu/Debian).

## Installation

Run the installer interactively as root. It is designed for interactive mode and reads prompts from /dev/tty.

Example:

	curl -fsSL https://raw.githubusercontent.com/maximilian-franz/basilvision-host-metrics/main/install.sh | sudo bash

What the installer does:

1. Installs required packages (git, curl, openssl, ca-certificates).
2. Clones or updates this repository to /opt/host-metrics.
3. Prompts for API URL, API key, device name, and device UUID.
4. Writes /opt/host-metrics/.env with your credentials.
5. Installs and links systemd service and timer units.
6. Enables and starts basilvision-push-metrics.timer.

## Runtime Configuration

Environment variables are stored in /opt/host-metrics/.env.

Variables:
- `API_URL` — HTTP endpoint that receives the metrics POST
- `API_KEY` — API key sent in the `x-api-key` header
- `NAME` — Human-readable device name included in the payload
- `DEVICE_UUID` — Stable unique identifier for this device

To update credentials, edit /opt/host-metrics/.env and restart the timer:

	sudo systemctl restart basilvision-push-metrics.timer

## Scheduling

The timer runs every 5 minutes with a 2-minute delay after boot, defined in [basilvision-push-metrics.timer](basilvision-push-metrics.timer):

	OnBootSec=2min
	OnUnitActiveSec=5min

To change the interval, edit the timer file and reload:

	sudo systemctl daemon-reload
	sudo systemctl restart basilvision-push-metrics.timer

## Useful Commands

Check timer:

	sudo systemctl status basilvision-push-metrics.timer

Run one push immediately:

	sudo systemctl start basilvision-push-metrics.service

See push logs:

	sudo journalctl -u basilvision-push-metrics.service -n 200 --no-pager

See timer logs:

	sudo journalctl -u basilvision-push-metrics.timer -n 200 --no-pager

## Updating

Re-run the installer to pull the latest repository version and re-apply configuration.

## Uninstall

Use the installer in uninstall mode:

	sudo bash install.sh --uninstall

If you do not have a local copy of the installer, you can uninstall directly from GitHub:

	curl -fsSL https://raw.githubusercontent.com/maximilian-franz/basilvision-host-metrics/main/install.sh | sudo bash -s -- --uninstall

Skip the confirmation prompt:

	sudo bash install.sh --uninstall --yes

From GitHub (no confirmation prompt):

	curl -fsSL https://raw.githubusercontent.com/maximilian-franz/basilvision-host-metrics/main/install.sh | sudo bash -s -- --uninstall --yes

What uninstall does:

- Stops and disables:
	- basilvision-push-metrics.timer
	- basilvision-push-metrics.service
- Removes systemd links:
	- /etc/systemd/system/basilvision-push-metrics.service
	- /etc/systemd/system/basilvision-push-metrics.timer
- Removes installed app directory:
	- /opt/host-metrics

## Troubleshooting

Push fails with HTTP error:
- Check `API_URL` and `API_KEY` in /opt/host-metrics/.env.
- Verify the host has internet access.
- Run `sudo systemctl start basilvision-push-metrics.service` and inspect logs with `journalctl`.

CPU temperature not included in payload:
- The script skips the temperature field if neither `/sys/class/thermal/thermal_zone0/temp` nor `vcgencmd` is available.
- This is expected on hosts without a thermal sensor; all other metrics are still pushed.

Timer not firing:
- Verify the timer is active: `sudo systemctl status basilvision-push-metrics.timer`.
- Check for clock or network issues if metrics are missing from the API.

## Security Notes

- Credentials are stored in /opt/host-metrics/.env (mode 640, owner root).
- The service runs as root with a restricted systemd sandbox (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ProtectHome`).

## Project Files

- [install.sh](install.sh): interactive installer
- [push_metrics.sh](push_metrics.sh): metrics collection and push script
- [basilvision-push-metrics.service](basilvision-push-metrics.service): oneshot systemd unit
- [basilvision-push-metrics.timer](basilvision-push-metrics.timer): schedule definition
