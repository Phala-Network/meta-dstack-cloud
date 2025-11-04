FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

do_install:append() {
    # Disable systemd-vconsole-setup.service
    rm -f ${D}${systemd_system_unitdir}/sysinit.target.wants/systemd-vconsole-setup.service
}

SYSTEMD_SERVICE:${PN}-vconsole-setup = ""
PACKAGECONFIG:remove = "sysvinit logind"
