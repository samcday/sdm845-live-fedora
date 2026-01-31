# sdm845-live-fedora

A proof of concept that uses [mkosi][] to generate a live rootfs directory
and a `rootfs.ero` artifact for sdm845 devices.

## Usage

NOTE: this is a very rough sketch until I've stabilized things further.

Build the rootfs artifacts:

```sh
mkosi
# the rootfs directory is located at mkosi.output/rootfs/
# the erofs image is located at mkosi.output/rootfs.ero
```

[mkosi]: https://github.com/systemd/mkosi
