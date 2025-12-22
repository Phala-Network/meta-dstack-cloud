do_install:append() {
    # Disable systemd-vconsole-setup.service
    rm -f ${D}${systemd_system_unitdir}/sysinit.target.wants/systemd-vconsole-setup.service

    # Ensure systemd-resolved waits for /var/volatile tmpfs and tmpfiles setup
    install -d ${D}${systemd_system_unitdir}/systemd-resolved.service.d
    cat <<'EOF' > ${D}${systemd_system_unitdir}/systemd-resolved.service.d/10-var-volatile.conf
[Unit]
After=systemd-tmpfiles-setup.service var-volatile.mount
Requires=var-volatile.mount
EOF
}

SYSTEMD_SERVICE:${PN}-vconsole-setup = ""
PACKAGECONFIG:remove = "sysvinit logind"
