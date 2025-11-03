include dstack-rootfs-base.inc

IMAGE_INSTALL += "packagegroup-core-ssh-openssh strace tcpdump gdb gdbserver vim"
EXTRA_IMAGE_FEATURES += "allow-empty-password allow-root-login empty-root-password post-install-logging tools-profile"
