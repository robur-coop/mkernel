Tests some simple unikernels
  $ solo5-hvt sleep.exe
              |      ___|
    __|  _ \  |  _ \ __ \
  \__ \ (   | | (   |  ) |
  ____/\___/ _|\___/____/
  Solo5: Bindings version v0.9.0
  Solo5: Memory map: 512 MB addressable:
  Solo5:   reserved @ (0x0 - 0xfffff)
  Solo5:       text @ (0x100000 - 0x1bafff)
  Solo5:     rodata @ (0x1bb000 - 0x1eafff)
  Solo5:       data @ (0x1eb000 - 0x250fff)
  Solo5:       heap >= 0x251000 < stack < 0x20000000
  Hello
  World
  Solo5: solo5_exit(0) called
  $ solo5-hvt schedule.exe
              |      ___|
    __|  _ \  |  _ \ __ \
  \__ \ (   | | (   |  ) |
  ____/\___/ _|\___/____/
  Solo5: Bindings version v0.9.0
  Solo5: Memory map: 512 MB addressable:
  Solo5:   reserved @ (0x0 - 0xfffff)
  Solo5:       text @ (0x100000 - 0x1bafff)
  Solo5:     rodata @ (0x1bb000 - 0x1eafff)
  Solo5:       data @ (0x1eb000 - 0x250fff)
  Solo5:       heap >= 0x251000 < stack < 0x20000000
  Hello
  World
  Solo5: solo5_exit(0) called
