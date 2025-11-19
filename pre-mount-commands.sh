cat <<'SH' >/tmp/pre-stage.sh
#!/bin/sh
echo 0 > /proc/sys/kernel/panic
echo 0 > /proc/sys/kernel/panic_on_oops
set -x
cat /proc/sys/kernel/panic
cat /proc/sys/kernel/panic_on_oops
SH
chmod +x /tmp/pre-stage.sh
echo '/tmp/pre-stage.sh' >> /etc/profile
SH
