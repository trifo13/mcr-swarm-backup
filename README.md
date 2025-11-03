# mcr-swarm-backup

1) Clone & review config:
git clone https://github.com/trifo13/mcr-swarm-backup
cd swarm-backup
# (optional) tweak defaults:
sed -n '1,200p' swarm-backup.conf

2) Install (copies files into place + enables the timer):
chmod +x install.sh swarm-backup.sh
sudo ./install.sh

What this does:

Installs the script → /usr/local/sbin/swarm-backup.sh
Installs config → /etc/swarm-backup.conf
Installs systemd units → /etc/systemd/system/swarm-backup.{service,timer}
Reloads systemd and enables the timer


3) Verify timer & test a run
systemctl status swarm-backup.timer --no-pager
# manual test run:
sudo systemctl start swarm-backup.service
journalctl -u swarm-backup.service -n 200 --no-pager
ls -1 /backup/swarm | tail -n 3

4) If you don’t want systemd:
sudo install -m 0755 swarm-backup.sh /usr/local/sbin/swarm-backup.sh
sudo install -m 0644 swarm-backup.conf /etc/swarm-backup.conf
# cron (as root) — runs daily at 03:17
( crontab -l 2>/dev/null; echo '17 3 * * * /usr/local/sbin/swarm-backup.sh >> /var/log/swarm-backup.log 2>&1' ) | crontab -

5) CLI overrides (take precedence over the conf), example:

# Run the script with custom backup directory and KEEP:
/usr/local/sbin/swarm-backup.sh -d /backup/swarm-alt -k 10

# Run the script with custom variables script:
/usr/local/sbin/swarm-backup.sh -c /root/my.vars

6) Uninstall:

From the repo:

sudo ./uninstall.sh
