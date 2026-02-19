# live-pocket-fedora

Some [mkosi][] configs to prepare an image that is suitable to live boot on
pocket computers, using [smoo][] + [fastboop][].

This serves as a testbed for stuff I hope to upstream in Fedora.

## Compose artifact pipeline

- Producer and CI flow: `docs/casync-compose.md`
- Manifest schema: `docs/compose-manifest.schema.json`
- Retention and GC plan: `docs/casync-retention-gc.md`

[mkosi]: https://github.com/systemd/mkosi
[smoo]: https://github.com/samcday/smoo
[fastboop]: https://github.com/samcday/fastboop
