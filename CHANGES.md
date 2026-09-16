### v0.0.4 (2026-08-25)

- Provide malloc statistic (@hannesm, @reynir, [!26][26], [!30][30])
- Introduce `Mkernel.finally` (@reynir, @dinosaure, [!23][23])
- Rename `Block.pagesize` to `Block.sector_size` (@dinosaure, @hannesm, @reynir, [!24][24])
- Add stubs for `mirage-mtime` (@hannesm, @dinosaure, [!25][25])
- Introduce a `Stats` module (@hannesm, @reynir, [!27][27])
- Introduce `Mkernel.now` (@dinosaure, @hannesm, [!28][28])
- Rename log source (@hannesm, @reynir, [!29][29])
- Embed MAC and MTU into the `Net.t` (@hannesm, @dinosaure, [!31][31])
- Remove unikraft from the documentation (@hannesm, @dinosaure, [!32][32])
- Use `memcpy` when we copy bigstring (@hannesm, @dinosaure, [#34][34], [!36][36])

[34]: https://git.robur.coop/robur/mkernel/issues/34
[23]: https://git.robur.coop/robur/mkernel/pulls/23
[24]: https://git.robur.coop/robur/mkernel/pulls/24
[25]: https://git.robur.coop/robur/mkernel/pulls/25
[26]: https://git.robur.coop/robur/mkernel/pulls/26
[27]: https://git.robur.coop/robur/mkernel/pulls/27
[28]: https://git.robur.coop/robur/mkernel/pulls/28
[29]: https://git.robur.coop/robur/mkernel/pulls/29
[30]: https://git.robur.coop/robur/mkernel/pulls/30
[31]: https://git.robur.coop/robur/mkernel/pulls/31
[32]: https://git.robur.coop/robur/mkernel/pulls/32
[36]: https://git.robur.coop/robur/mkernel/pulls/36

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
