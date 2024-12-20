# Miou & Solo5

This library can be used to create unikernels with [Miou][miou] and
[Solo5][solo5]. The library exposes what Solo5 can expose and implements a
simple scheduler using Miou in order to develop a unikernel. Examples are
available in the [tests][tests] to show how to implement and build an
unikernel.

Basically, a unikernel can be built from 2 devices:
- the net device (a [TAP interface][tap])
- the device block (a simple file)

## How to build an unikernel with Miou & Solo5

Here's an example of a simple unikernel with `Miou_solo5` which displays
"Hello World":
```ocaml
let () = Miou_solo5.(run []) @@ fun () ->
  print_endline "Hello World"
```

First of all, we can build a simple executable from this code:
```dune
(executable
 (name main)
 (modules main)
 (modes native)
 (link_flags :standard -cclib "-z solo5-abi=hvt")
 (libraries miou-solo5)
 (foreign_stubs
  (language c)
  (names manifest.sleep)))
```

As you can see, the executable needs a "manifest.c". This is a file that
describes the devices that the unikernel needs. In this case, the `run`
function takes a list of devices as its first argument, and we have just
specified no devices in our example.

As far as our _host toolchain_ is concerned, we can generate an empty file for
the "manifest.c" required:
```dune
(rule
 (targets manifest.c)
 (enabled_if
  (= %{context_name} "default"))
 (action
  (write-file manifest.c "")))
```

Our first objective is to _infer_ the devices needed for our unikernel. In this
case, our unikernel in our host context is not really going to run. It will
collect the devices we have in the list we pass to `Miou_solo5.run` and generate
a JSON file describing the devices needed by our unikernel.
```shell
$ dune exec main.exe
{"type":"solo5.manifest","version":1,"devices":[]}
```

We can now specify a new toolchain, that of solo5 (available via the
[ocaml-solo5][ocaml-solo5] package) so that we can compile our OCaml code and
build our unikernel.
```shell
$ cat >dune-workspace <<EOF
(lang dune 3.0)
(context (default))
(context (default
 (name solo5)
 (host default)
 (toolchain solo5)
 (merlin)
 (disable_dynamically_linked_foreign_archives true)))
EOF
```

However, this time the "manifest.c" file must not be empty. It will be the
result of a tool, `solo5-elftool` (available via the `solo5` package), which
generates the "manifest.c" file from a "manifest.json" file describing the
devices needed for our unikernel.

We are going to describe two new rules. The first will generate our
"manifest.json" from our unikernel compiled in the host context, and the second
will use this "manifest.json" to generate the "manifest.c" file in the Solo5
context:
```dune
(rule
 (targets manifest.c)
 (deps manifest.json)
 (enabled_if
  (= %{context_name} "solo5"))
 (action
  (run solo5-elftool gen-manifest manifest.json manifest.c)))

(rule
 (targets manifest.json)
 (enabled_if
  (= %{context_name} "solo5"))
 (action
  (with-stdout-to
   manifest.json
   (run %{exe:main.exe}))))
```

We can now compile our unikernel with a simple: `dune build`!
```shell
$ dune build
$ solo5-hvt _build/solo5/main.exe --solo5:quiet
Hello World
```

The executable `_build/solo5/main.exe` is not really an executable but an OS!
What's more, you can't run it as a simple program but "virtualise" it using the
_tender_ `solo5-hvt`. Congratulations, you've made a _complete_ operating
system in OCaml!
