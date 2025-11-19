```

--enforce-eager --model openai/gpt-oss-120b --tensor-parallel-size 4 --gpu-memory-utilization 0.92 --max-model-len 32768
      
      
```


In some situations, your applications might require you to build your own operating system or compile a custom kernel. If you compile custom kernels or create custom operating systems for your VMs, ensure that they meet the requirements in this document.

[Building a custom operating system](https://docs.cloud.google.com/compute/docs/images/create-custom) is an advanced task for users with applications that specifically require a custom kernel. Most users can create VMs from one of the available [public images](https://docs.cloud.google.com/compute/docs/images#os-compute-support), use the automated [virtual disk import tool](https://docs.cloud.google.com/compute/docs/import/importing-virtual-disks) to import disks into Compute Engine from other environments, or [manually import a custom image](https://docs.cloud.google.com/compute/docs/import/import-existing-image) from a system with a common stock Linux distribution.

## Hardware support requirements

Your kernel must support the following devices:

- PCI Bridge: Intel Corporation 82371AB/EB/MB PIIX4 ACPI (rev 03)
- ISA bridge: Intel 82371AB/EB/MB PIIX4 ISA (rev 03)
- Ethernet controller:
    
    - Virtio-Net Ethernet Adapter.
    - vendor = 0x1AF4 (Qumranet/Red Hat)
    - device id = 0x1000. Subsystem ID 0x1
    - Checksum offload is supported
    - TSO v4 is supported
    - GRO v4 is supported
        
- SCSI Storage Controller:
    
    - Virtio-SCSI Storage Controller
    - vendor = 0x1AF4 (Qumranet/Red Hat)
    - device id = 0x1004. Subsystem ID 0x8.
    - SCSI Primary Commands 4 and SCSI Block Commands 3 are supported
    - Only one request queue is supported
    - Persistent disks report 4 KiB physical sectors / 512 byte logical sectors
    - Only block devices (disks) are supported
    - The Hotplug / Events feature bit is supported

**Note:** For second generation Tau T2A and G2, and all third generation and later machine series, you must use an NVMe storage controller instead.

- Serial Ports:
    - Four 16550A ports
    - ttyS0 on IRQ 4
    - ttyS1 on IRQ 3
    - ttyS2 on IRQ 6
    - ttyS3 on IRQ 7

## Required Linux kernel build options

You must build the operating system kernel with the following options:

- `CONFIG_KVM_GUEST=y`
    - Enable paravirtualization functionality.
- `CONFIG_KVM_CLOCK=y`
    - Enable the paravirtualized clock (if applies to your kernel version).
- `CONFIG_VIRTIO_PCI=y`
    - Enable paravirtualized PCI devices.
- `CONFIG_SCSI_VIRTIO=y`
    - Enable access to paravirtualized disks.
- `CONFIG_VIRTIO_NET=y`
    - Enable access to networking.
- `CONFIG_PCI_MSI=y`
    - Enable high-performance interrupt delivery, which is required for local SSD devices.

### Kernel build options for security

Use the recommended security settings in your kernel build options:

- `CONFIG_STRICT_DEVMEM=y`
    - Restrict `/dev/mem` to allow access to only PCI space, BIOS code, and data regions.
- `CONFIG_DEVKMEM=n`
    - Disable support for `/dev/kmem`.
    - Block access to kernel memory.
- `CONFIG_DEFAULT_MMAP_MIN_ADDR=65536`
    - Set low virtual memory that is protected from userspace allocation.
- `CONFIG_DEBUG_RODATA=y`
    - Mark the kernel read-only data as write-protected in the pagetables, to catch accidental (and incorrect) writes to such `const` data. This option can have a slight performance impact because a portion of the kernel code won't be covered by a 2 MB TLB anymore.
- `CONFIG_DEBUG_SET_MODULE_RONX=y`
    - Catches unintended modifications to loadable kernel module's text and read-only data. This option also prevents execution of module data.
- `CONFIG_CC_STACKPROTECTOR=y`
    - Enables the `-fstack-protector` GCC feature. This feature puts a canary value at the beginning of critical functions, on the stack before the return address, and validates the value before actually returning. This also causes stack-based buffer overflows (that need to overwrite this return address) to overwrite the canary, which gets detected and the attack is then neutralized using a kernel panic.
- `CONFIG_COMPAT_VDSO=n`
    - Ensures the VDSO isn't at a predictable address to strengthen ASLR. If enabled, this feature maps the VDSO to the predictable old-style address, providing a predictable location for exploit code to jump to. Say `N` here if you are running a sufficiently recent `glibc` version (2.3.3 or later), to remove the high-mapped VDSO mapping and to exclusively use the randomized VDSO.
- `CONFIG_COMPAT_BRK=n`
    - Don't disable heap randomization.
- `CONFIG_X86_PAE=y`
    - Set this option for a 32-bit kernel because PAE is required for NX support. This also enables larger swapspace support for non-overcommit purposes.
- `CONFIG_SYN_COOKIES=y`
    - Provides some protection against SYN flooding.
- `CONFIG_SECURITY_YAMA=y`
    - This selects Yama, which extends DAC support with additional system-wide security settings beyond regular Linux discretionary access controls. Currently, the setting is ptrace scope restriction.
- `CONFIG_SECURITY_YAMA_STACKED=y`
    - This option forces Yama to stack with the selected primary LSM when Yama is available.
