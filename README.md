# mcr-swarm-backup

Small, reliable backups for **Docker Swarm** managers.  
Skips on the **leader**, runs on **one** non-leader (NFS lock), and supports **systemd** or **cron**.

---

## 1) Clone & review config

```bash
git clone https://github.com/trifo13/mcr-swarm-backup
cd mcr-swarm-backup
# (optional) tweak defaults:
sed -n '1,200p' swarm-backup.conf
```

---

## 2) Install (copies files + enables the timer)

```bash
chmod +x install.sh swarm-backup.sh
sudo ./install.sh
```

**What this does**
- Installs the script → `/usr/local/sbin/swarm-backup.sh`  
- Installs config → `/etc/swarm-backup.conf`  
- Installs systemd units → `/etc/systemd/system/swarm-backup.{service,timer}`  
- Reloads systemd and **enables the timer**

---

## 3) Verify timer & test a run

```bash
systemctl status swarm-backup.timer --no-pager

# manual test run:
sudo systemctl start swarm-backup.service

journalctl -u swarm-backup.service -n 200 --no-pager
ls -1 /backup/swarm | tail -n 3
```

---

## 4) If you don’t want systemd

```bash
# install script + config
sudo install -m 0755 swarm-backup.sh /usr/local/sbin/swarm-backup.sh
sudo install -m 0644 swarm-backup.conf /etc/swarm-backup.conf

# cron (as root) — runs daily at 03:17
( crontab -l 2>/dev/null; echo '17 3 * * * /usr/local/sbin/swarm-backup.sh >> /var/log/swarm-backup.log 2>&1' ) | crontab -
```

---

## 5) CLI overrides (take precedence over the conf)

```bash
# Run the script with custom backup directory and KEEP:
sudo /usr/local/sbin/swarm-backup.sh -d /backup/swarm-alt -k 10

# Run the script with a custom variables file:
sudo /usr/local/sbin/swarm-backup.sh -c /root/my.vars
```

> Tip: If you change `BACKUP_DIR`, update your systemd unit’s
> `RequiresMountsFor=` and `ConditionPathIsMountPoint=` **or** set
> `REQUIRE_MOUNTPOINT=1` in `/etc/swarm-backup.conf`.

---

## 6) Uninstall

From the repo:

```bash
sudo ./uninstall.sh
```

---

## Troubleshooting

“NFS not mounted” / service skipped
Ensure your NFS is mounted at BACKUP_DIR. If you enforce the mount (REQUIRE_MOUNTPOINT=1 or unit conditions), the service will skip otherwise.

Two managers ran simultaneously
Check your NFS (use NFSv4 if possible). The lock dir .swarm-backup.lock should be on the shared path.

Backups not pruned
Confirm KEEP is a non-negative integer and filenames match swarm-*.tgz.

Changed BACKUP_DIR but unit still points to /backup/swarm
Update RequiresMountsFor= and ConditionPathIsMountPoint= in the service file, then:

```bash
sudo systemctl daemon-reload
sudo systemctl restart swarm-backup.timer
```

---

## Security

Archives include Swarm internal data; protect the NFS export and directory permissions.

Consider encrypting backups or mounting NFS over a secure network.

---

## License

MIT (feel free to adapt for your environment).
