# OCaml & unikernel, next steps!

1) restart from the roots
2) show new experimentations about OCaml 5 and unikernels
3) explain a possible new workflow to build unikernels
4) discuss/debate about the future

---

## Show me a simple example!

Our unikernel as a `main.c` code source:
```c
#include "solo5.h"

const char hello[] = "Hello World!\n";

int solo5_app_main(const struct solo5_start_info *si __attribute__((unused))) {
  solo5_console_write(hello, sizeof(hello));
  return (0);
}
```

We need a `manifest.json` (which describes devices required by our unikernel):
```json
{
  "type": "solo5.manifest",
  "version": 1,
  "devices": []
}
```

We finally can compile & run it:
```
$ x86_64-solo5-none-static-cc -c main.c -o main.o
$ solo5-elftool gen-manifest manifest.json manifest.c
$ x86_64-solo5-none-static-cc -c manifest.c -o manifest.o
$ x86_64-solo5-none-static-ld -z solo5-abi=hvt manifest.o main.o -o main.hvt
$ solo5-hvt main.hvt
            |      ___|
  __|  _ \  |  _ \ __ \
\__ \ (   | | (   |  ) |
____/\___/ _|\___/____/
Solo5: Bindings version v0.9.1
Solo5: Memory map: 512 MB addressable:
Solo5:   reserved @ (0x0 - 0xfffff)
Solo5:       text @ (0x100000 - 0x103fff)
Solo5:     rodata @ (0x104000 - 0x104fff)
Solo5:       data @ (0x105000 - 0x109fff)
Solo5:       heap >= 0x10a000 < stack < 0x20000000
Hello World!
Solo5: solo5_exit(0) called
```

---

## Solo5 and OCaml

Let's start with a simple code (`main.ml`):
```ocaml
let () = print_endline "Hello World!"
```

We also need a _glue_ between Solo5 (`solo5_app_main`) and OCaml (`caml_startup`):
```c
#include "solo5.h"
#include <caml/callback.h>

static char *argv[] = { "unikernel", NULL };

void _nolibc_init(uintptr_t, size_t);

int solo5_app_main(const struct solo5_start_info *si) {
  _nolibc_init(si->heap_start, si->heap_size);
  caml_startup(argv);
  return (0);
}
```

Let's compile & run it:
```
$ ocamlfind -toolchain solo5 opt -c startup.c -o startup.o
$ solo5-elftool gen-manifest manifest.json manifest.c
$ x86_64-solo5-none-static-cc -c manifest.c -o manifest.o
$ ocamlfind -toolchain solo5 opt startup.o manifest.o main.ml -cclib '-z solo5-abi=hvt' -o main.hvt
$ solo5-hvt main.hvt
            |      ___|
  __|  _ \  |  _ \ __ \
\__ \ (   | | (   |  ) |
____/\___/ _|\___/____/
Solo5: Bindings version v0.9.1
Solo5: Memory map: 512 MB addressable:
Solo5:   reserved @ (0x0 - 0xfffff)
Solo5:       text @ (0x100000 - 0x149fff)
Solo5:     rodata @ (0x14a000 - 0x161fff)
Solo5:       data @ (0x162000 - 0x16cfff)
Solo5:       heap >= 0x16d000 < stack < 0x20000000
Hello World!
Solo5: solo5_exit(0) called
```

---

## What Solo5 and OCaml can propose?

Mainly... nothing. `ocaml-solo5` is just the OCaml runtime (GC, OCaml stack) compiled with Solo5.

It is therefore possible to run so-called _pure_ OCaml code.

### Pure means no interaction with the outside world

⨯ You can **not** read/write files (no `open_{in,out}`) — there is no file system.

⨯ Even though we are using OCaml 5, we only have one core (no `Domain.spawn`).

⨯ The `Unix` module is **not** available (no `Unix.socket`) — there is no network implementation.

Solo5 and `ocaml-solo5` **only** offers 5 functions for interacting with the outside world.

---

## How an unikernel can meet the world?

```
~~~graph-easy
[ unikernel ] <- hypercall -> [ solo5-hvt ] <- syscall -> [ host kernel ]
~~~
```

Solo5 provides 5 _hypercalls_ which are translated to _syscalls_:
1) write a _page_ into a _block device_ (like a hard drive)
2) read a _page_ from a _block device_
3) write an Ethernet frame into a _virtual net interface_ (like an Ethernet cable)
4) read an Ethernet frame (this _hypercall_ can **block**)
5) shutdown

```ocaml
external solo5_net_acquire :
     name:string
  -> file_descr * { mac : bytes; mtu : int; }
  = "solo5_net_acquire"
[@@noalloc]

external solo5_net_read :
     file_descr
  -> bigstring
  -> off:(int[@untagged])
  -> len:(int[@untagged])
  -> (int[@untagged]) = "solo5_net_read"
[@@noalloc]

external solo5_net_write :
     file_descr
  -> off:(int[@untagged])
  -> len:(int[@untagged])
  -> bigstring
  -> (int[@untagged]) = "solo5_net_write"
[@@noalloc]

external solo5_block_acquire :
     name:string
  -> file_descr * { length: int64; pagesize: int; }
  = "solo5_block_acquire"
[@@noalloc]

external solo5_block_read :
     file_descr
  -> off:(int[@untagged])
  -> len:(int[@untagged])
  -> bigstring
  -> (int[@untagged]) = "solo5_block_read"
[@@noalloc]

external solo5_block_write :
     file_descr
  -> off:(int[@untagged])
  -> len:(int[@untagged])
  -> bigstring
  -> (int[@untagged]) = "solo5_block_write"
[@@noalloc]
```

---

## Synchronous _hypercalls_

Solo5 does **not** provide a _scheduler_. If you want to read an Ethernet frame, the unikernel will **wait** for an Ethernet frame.

However, Solo5 offers a `yield` function:

```ocaml
external solo5_yield : timeout:float -> file_descr list
  = "solo5_yield"
[@@noalloc]
```

It allows you to wait for a certain amount of time (`timeout`) and is interrupted as soon as a new Ethernet frame arrives.

---

## Solo5, C and OCaml

Solo5 is written in C. The framework offers minimal interaction with the outside world, thus avoiding complex implementations that could only be done in C (scheduler, memory map, Symmetric MultiProcessing).

The advantage is that this complexity can be transferred to OCaml.

We therefore need to develop:
- a scheduler in OCaml
- FFI to Solo5 (as we shown you above)
- network protocols based on Ethernet frames in OCaml
- file systems based on atomic access to block devices in OCaml

---

## Scheduler, introduction to Miou (`mkernel`)

Miou is a simple scheduler in OCaml (using effects). Its task management policy is similar to `async` in order to make a Miou application as **available as possible** when receiving external events.

The advantage of this type of task management lies in the ambition to implement services such as unikernels.

```ocaml
let _1s = 1_000_000_000

let () =
  Mkernel.run [] @@ fun () ->
  let prm = Miou.async @@ fun () ->
    print_endline "Hello" in
  Mkernel.sleep _1s;
  print_endline "World";
  Miou.await_exn prm
```

```
$ solo5-hvt main.hvt
            |      ___|
  __|  _ \  |  _ \ __ \
\__ \ (   | | (   |  ) |
____/\___/ _|\___/____/
Solo5: Bindings version v0.9.1
Solo5: Memory map: 512 MB addressable:
Solo5:   reserved @ (0x0 - 0xfffff)
Solo5:       text @ (0x100000 - 0x1c0fff)
Solo5:     rodata @ (0x1c1000 - 0x1f2fff)
Solo5:       data @ (0x1f3000 - 0x259fff)
Solo5:       heap >= 0x25a000 < stack < 0x20000000
Hello
... (wait 1s)
World
Solo5: solo5_exit(0) called
```

---

## FFI, example with a block device

`mkernel` implements FFI for Solo5:

```ocaml
let () =
  Mkernel.(run [ block "file" ]) @@ fun blk () ->
  let pagesize = Mkernel.Block.pagesize blk in
  let bstr = Bstr.create pagesize in
  Mkernel.Block.read blk ~off:0 bstr;
  Fmt.pr "@[<hov>%a@]\n" (Hxd_string.pp Hxd.default) (Bstr.to_string bstr)
```

We must specify a new _device_ in our `manifest.json`:

```json
{
  "type":"solo5.manifest",
  "version":1,
  "devices": [
    { "name":"simple", "type":"BLOCK_BASIC" }
  ]
}
```

This is how we should invoke solo5-hvt to launch our unikernel.

```
$ dune build ./main.exe
$ echo "Hello World!" > file.txt
$ truncate -s 512 file.txt
$ solo5-hvt --block:file=file.txt _build/solo5/main.exe
            |      ___|
  __|  _ \  |  _ \ __ \
\__ \ (   | | (   |  ) |
____/\___/ _|\___/____/
Solo5: Bindings version v0.9.1
Solo5: Memory map: 512 MB addressable:
Solo5:   reserved @ (0x0 - 0xfffff)
Solo5:       text @ (0x100000 - 0x1d8fff)
Solo5:     rodata @ (0x1d9000 - 0x20efff)
Solo5:       data @ (0x20f000 - 0x285fff)
Solo5:       heap >= 0x286000 < stack < 0x20000000
00000000: 4865 6c6c 6f20 576f 726c 6421 0a00 0000  Hello World!....
00000010: 0000 0000 0000 0000 0000 0000 0000 0000  ................
...
000001f0: 0000 0000 0000 0000 0000 0000 0000 0000  ................
Solo5: solo5_exit(0) called
```

---

## Wait, `dune build ./main.exe`?

`dune` handles `ocamlfind`'s toolchains. We just need to create a new `dune`'s context via a `dune-workspace`:

```
(lang dune 3.0)
(context (default))
(context (default
 (name solo5)
 (host default)
 (toolchain solo5)
 (merlin)
 (disable_dynamically_linked_foreign_archives true)))
```

Then, we just describe our unikernel as a simple executable into the `dune` file:

```
(executable
 (name main)
 (modules main)
 (modes native)
 (link_flags :standard -cclib "-z solo5-abi=hvt")
 (libraries mkernel)
 (foreign_stubs
  (language c)
  (names manifest)))
```

---

### How we handle the `manifest.json` required to build the unikernel?

However, we need to obtain `manifest.c` via `solo5-elftool`.

```
(rule
 (targets manifest.c)
 (deps manifest.json)
 (action
  (run solo5-elftool gen-manifest manifest.json manifest.c)))
```

We can therefore:
- either write the `manifest.json` manually
- or use a tool that inspects our `main.ml` and generates the `manifest.json`

---

### `mkernel` can also generate the `manifest.json`

When there are two toolchains, as soon as an executable needs to be compiled, it is compiled twice.

So, `dune` compiles a simple executable from our `main.ml`, but also an unikernel.

The simple executable **does not make sense**.

However, we can reuse this target (`default:main.exe`) to generate an executable which, depending on the Solo5 interactions used into the the `main.ml`, allows us to aggregate the devices needed for our unikernel.

```
$ dune exec ./main.exe
{
  "type":"solo5.manifest",
  "version":1,
  "devices": [
   { "name":"simple", "type":"BLOCK_BASIC" }
  ]
}
```

Here is the compilation pipeline:

```
~~~graph-easy -as boxart
[ dune build ] -> [ default:main.exe] -> [ default:manifest.json ]
[ dune build ] -> [ default:manifest.json ] -> [ solo5:manifest.c ]
[ dune build ] -> [ solo5:main.exe ]
[ solo5:manifest.c ] -> [ solo5:main.exe ]
~~~
```

---

## How to use third-party libraries in an unikernel?

Simply **vendor** (`git submodule`) the library and add its name to the `libraries` field of your executable.

However, `ocaml-solo5` has one useful feature: it does not change the way OCaml files are compiled. It simply provides a different OCaml runtime (`libasmrun.a`). If a library is written entirely in OCaml (no C stubs), you can use the one available in your `opam` switch:

```ocaml
let run foo bar =
  Mkernel.(run []) @@ fun () ->
  Fmt.pr "foo: %d\n%!" foo;
  Fmt.pr "bar: %S\n%!" bar

open Cmdliner

let foo = Arg.(value & opt int 42 & info [ "foo" ])
let bar = Arg.(value & opt string "Hello World!" & info [ "bar "])

let term = Term.(const run $ foo $ bar)
let info = Cmd.info "unikernel"
let cmd = Cmd.v info term
let () = Cmd.(exit @@ eval cmd)
```

And you can pass arguments to your unikernel (even `--help` works!):

```
$ opam install cmdliner
$ dune build ./main.exe
$ solo5-hvt -- _build/solo5/main.exe --foo 100 --bar "Retreat!"
            |      ___|
  __|  _ \  |  _ \ __ \
\__ \ (   | | (   |  ) |
____/\___/ _|\___/____/
Solo5: Bindings version v0.9.1
Solo5: Memory map: 512 MB addressable:
Solo5:   reserved @ (0x0 - 0xfffff)
Solo5:       text @ (0x100000 - 0x1eafff)
Solo5:     rodata @ (0x1eb000 - 0x224fff)
Solo5:       data @ (0x225000 - 0x2b1fff)
Solo5:       heap >= 0x2b2000 < stack < 0x20000000
foo: 100
bar: "Retreat!"
Solo5: solo5_exit(0) called
```

---

## And the network?

Robur has an expertise in protocol implementation. We have an implementation of the TCP/IP protocol in OCaml called `utcp`:

```ocaml
let echo_handler flow =
  let finally () = TCPv4.close flow in
  Fun.protect ~finally @@ fun () ->
  let buf = Bytes.create 0x7ff in
  let rec go () =
    let len = TCPv4.read flow buf ~off:0 ~len:(Bytes.length buf) in
    if len > 0
    then go (TCPv4.write flow (Bytes.sub_string buf 0 len)) in
  go

let run cidr gateway =
  Mkernel.(run [ tcpv4 ~name:"service" ?gateway cidr ]) @@ fun (daemon, tcpv4) () ->
  let rng = Mirage_crypto_rng_miou_solo5.initialize (module Mirage_crypto_rng.Fortuna) in
  let finally () =
    Mirage_crypto_rng_miou_solo5.kill rng;
    TCPv4.kill daemon in
  Fun.protect ~finally @@ fun () ->
  let t = TCPv4.listen tcpv4 3000 in
  let rec go orphans =
    clean orphans;
    let flow = TCPv4.accept tcpv4 t in
    let _, (ipaddr, port) = TCPv4.peers flow in
    Logs.debug (fun m -> m "new incoming connection from %a:%d" Ipaddr.pp ipaddr port);
    ignore (Miou.async ~orphans (echo_handler flow));
    go orphans in
  go (Miou.orphans ())
```

Here's how to create a virtual Ethernet interface and how to launch our unikernel with this interface.

```
$ sudo ip link add name service type bridge
$ sudo ip addr add 10.0.0.1/24 dev service
$ sudo ip tuntap add dev tap0 mode tap
$ sudo ip link set tap0 master service
$ sudo ip link set dev tap0 up
$ sudo ip link set service up
$ dune build ./main.exe
$ solo5-hvt --net:service=tap0 -- _build/solo5/main.exe --ipv4=10.0.0.2/24 --ipv4-gateway=10.0.0.1
            |      ___|
  __|  _ \  |  _ \ __ \
\__ \ (   | | (   |  ) |
____/\___/ _|\___/____/
Solo5: Bindings version v0.9.1
Solo5: Memory map: 512 MB addressable:
Solo5:   reserved @ (0x0 - 0xfffff)
Solo5:       text @ (0x100000 - 0x2f8fff)
Solo5:     rodata @ (0x2f9000 - 0x368fff)
Solo5:       data @ (0x369000 - 0x4c4fff)
Solo5:       heap >= 0x4c5000 < stack < 0x20000000
```

And we can communicate with our unikernel!

```
$ nc -n 10.0.0.2 3000
Retreat!
Retreat!
```

---

## Results

At this stage, we can therefore offer:
- a scheduler for OCaml 5 (Miou & `mkernel`)
- basic interactions for interacting with the rest of the world (via network interfaces or block devices)
- the beginnings of a TCP/IP stack using `utcp`
- so now we can start having fun!

---

## Comparisons

- the `mirage` tool is no longer used to produce an unikernel.
  + no more `config.ml`
  + a _one-stage_ compilation without extra operations to build an unikernel.
- we no longer need functors...
- it's probably more straitforward to develop an unikernel.

---

### A few additions

Although we are interested in the development of the unikernel, we would sometimes like to obtain an “executable” of our unikernel in order to obtain metrics (speed and memory usage).

The `default:main.exe` is able to be executated (as a simple executable) if `MIOU_PROFILING` (with a description of devices) is provided.

```json
{ "devices": [
    {
      "name": "service",
      "type": "NET_BASIC",
      "interface": "tap0"
    }
  ],
  "type": "miou.solo5.profiling",
  "version": 1
}
```

```
$ MIOU_PROFILING=profiling.json dune exec ./main.exe -- ...
```

---

### Eio and Miou

As we said, Miou is interested in the **availability** of an application rather than its speed.

This feature (which makes it different from Eio) reduces the latency of a service (such as a HTTP service).

|                         | httpun+eio | httpaf+miou |
|-------------------------|------------|-------------|
|    8 clients, 8 threads |   327.14us |     32.54us |
| 512 clients, 32 threads |     1.88ms |      1.07ms |
|  16 clients, 32 threads |   808.30us |     39.22us |
|  32 clients, 32 threads |     1.23ms |     64.83us |
|  64 clients, 32 threads |     1.26ms |    124.32us |
| 128 clients, 32 threads |     1.15ms |    263.56us |
| 256 clients, 32 threads |     1.25ms |    471.59us |
| 512 clients, 32 threads |     1.89ms |      0.98ms |
