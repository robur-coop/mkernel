### v0.0.3 (2026-07-28)

- Clean-up the distribution and remove the unikraft support (@dinosaure, #18)
- Add `Mkernel.wakeup` (@dinosaure, #18)

  `Mkernel.wakeup` is better if you would like to wake up a task at a specific date
  instead of `Mkernel.sleep` (which is better for small amount of times)

- Fix `Mkernel.wakeup` (@dinosaure, #19)
- Better way to handle and clean-up sleepers (@dinosaure, #20)
- Delete useless `Gc.compact` when we trigger a major cycle (@dinosaure, be761d5)
- Add `Mkernel.heap_size` (@dinosaure, #21)

### v0.0.2 (2026-05-06)

- Precise nanoseconds for `clock_{monotonic,wall}` (@hannesm, [!14][14])
- Run `solo5_yield` every 100ms to catch possible events even if we don't have
  (yet) syscalls to consume them and tasks to run (@dinosaure, [!15][15])

[14]: https://git.robur.coop/robur/mkernel/pulls/14
[15]: https://git.robur.coop/robur/mkernel/pulls/15

### v0.0.1 (2026-02-09)

- First public release of `mkernel`
