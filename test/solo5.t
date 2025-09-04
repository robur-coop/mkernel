Tests some simple unikernels with Solo5
  $ solo5-hvt sleep.exe --solo5:quiet
  Hello
  World
  $ solo5-hvt schedule.exe --solo5:quiet
  Hello
  World
  $ chmod +w simple.txt
  $ solo5-hvt --block:0=simple.txt --block-sector-size:0=512 block.exe --solo5:quiet
  00000000: 94a3b2375dd8aa75e3d2cdef54179909
  00000200: 5e00b6c8f387deac083b9718e08a361b
  $ solo5-hvt cmdline.exe --solo5:quiet --foo Foo --bar Bar
  uniker.ml --foo Foo --bar Bar
  foo: Some "Foo"
  bar: Some "Bar"
