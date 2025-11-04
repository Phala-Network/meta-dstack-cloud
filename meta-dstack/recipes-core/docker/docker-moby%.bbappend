FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SYSTEMD_SERVICE:${PN}:append = " docker.service"

SRC_URI += "file://docker.service.d_override.conf"
FILES:${PN} += "${systemd_system_unitdir}/docker.service.d/override.conf"

do_install:append() {
    if ${@bb.utils.contains('DISTRO_FEATURES', 'systemd', 'true', 'false', d)}; then
        install -d ${D}${systemd_system_unitdir}/docker.service.d
        src="${WORKDIR}/docker.service.d_override.conf"
        if [ -n "${UNPACKDIR}" ] && [ -f "${UNPACKDIR}/docker.service.d_override.conf" ]; then
            src="${UNPACKDIR}/docker.service.d_override.conf"
        fi
        install -m 0644 "${src}" ${D}${systemd_system_unitdir}/docker.service.d/override.conf
    fi
}
