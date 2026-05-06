### v0.0.2 (2026-05-06)

- Precise nanoseconds for `clock_{monotonic,wall}` (@hannesm, [!14][14])
- Run `solo5_yield` every 100ms to catch possible events even if we don't have
  (yet) syscalls to consume them and tasks to run (@dinosaure, [!15][15])

[14]: https://git.robur.coop/robur/mkernel/pulls/14
[15]: https://git.robur.coop/robur/mkernel/pulls/15

### v0.0.1 (2026-02-09)

- First public release of `mkernel`
