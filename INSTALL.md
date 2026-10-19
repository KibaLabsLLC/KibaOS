# Installing KibaOS

## Building the images

Set up the build environment and configure a build as described in [Building](README.md#building). Then build the image you need from the output folder, for example `output-Clang-amd64-debug`:

| Command | Creates | Use it to |
|---|---|---|
| `ninja bootcd` | `bootcd.iso` | Run KibaOS from a CD image, or start KibaOS Setup from it and install KibaOS on a disk. |
| `ninja kibaosimg` | `KibaOS.img` | Boot a disk with KibaOS already installed. It boots with UEFI or BIOS. |
| `ninja kibaosvhd` | `KibaOS.vhd` | Use the same preinstalled disk in virtual machines that take VHD disks, such as Hyper-V and VirtualBox. |

Each target builds everything it needs first, and the files are written to the output folder.

## Installing from the setup CD

Boot `bootcd.iso` in a virtual machine or on a PC, and follow the instructions of KibaOS Setup. Setup lists the drives the way Windows Setup does, and can create, delete, format, shrink and extend partitions. It installs KibaOS on NTFS and creates the EFI system partition it needs.

## Using the preinstalled disk

`KibaOS.img` needs no setup. Start it in a virtual machine such as QEMU, or write it to a USB drive or an SD card and boot the machine from it. Use `KibaOS.vhd` for virtual machines that take VHD disks.

The preinstalled disk also carries KibaOS Setup. Run `C:\<architecture>\kibaos.exe`, for example `C:\arm64\kibaos.exe`, to install KibaOS on another disk from the running system.

## Help

If something goes wrong, report it in [Issues](https://github.com/ahmedarif193/KibaOS/issues) with the architecture, the build type, the commit you built and the steps that lead to the problem. Guides and notes are in the [Wiki](https://github.com/ahmedarif193/KibaOS/wiki), and you can ask the team on [Discord](https://discord.gg/BpcKg7FZ2) or [Matrix](https://matrix.to/#/#kibaos:matrix.org).
