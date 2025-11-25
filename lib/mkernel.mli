(** A simple scheduler for Solo5/Unikraft in OCaml.

    A unikernel is a fully-fledged operating system that essentially wants to be
    virtualised into a host system such as Linux (KVM) or FreeBSD (Bhyve). In
    this sense, a unikernel's interactions with the {i outside world} (with
    other systems) via {i components} are standardised through two types of
    devices:
    - a net interface that emulates an Ethernet port
    - a block interface that emulates a hard drive

    These interactions respond to events transmitted by the host system, which
    retains exclusive direct access to physical components, retrieved by a
    {i tender} that runs in the host system's user space and is then
    retransmitted to the unikernel running in its own space.

    The information transmitted between the unikernel and the tender is called a
    {i hypercall}, and the information transmitted between the tender and the
    host system is called a {i syscall}. In other words, a {i hypercall}
    necessarily involves one or more {i syscalls}, and the transmission of the
    result necessarily passes through the tender (which serves as a bridge
    between the unikernel and the host system).

    Since these events originate from the {i outside world}, they can occur at
    any time. It is therefore necessary to be able to manage these events
    {i asynchronously} so as not to block the reception of a particular event
    and to be able to do {i something else} while waiting for certain events.

    This library therefore offers two essential features:
    - the ability to emit hypercalls as a virtualised unikernel
    - the ability to launch and manage tasks asynchronously into our unikernel:
      in other words, a scheduler

    {2 Scheduler.}

    A unikernel has exclusive use of a CPU and a memory area separate from the
    host system. This CPU simply executes the unikernel code. To date, there is
    no support for multiple cores. However, a scheduler is certainly needed in
    order to be able to execute multiple tasks {i at the same time}.

    As such, this library is based on the Miou scheduler. It is a small
    scheduler that uses the effects of OCaml 5 and allows tasks to be launched
    and managed asynchronously. Miou's objective is focused on the development
    of applications that are services (such as a web server). The task
    management policy is therefore designed so that the unikernel can handle as
    many hypercalls as possible. This contrasts with a scheduler that would
    optimise task scheduling in order to complete a calculation as quickly as
    possible (in other words, a CPU-bound application). Miou is therefore said
    to be a scheduler for I/O-bound applications.

    For more information about Miou and its task management and API, please read
    the {{:https://docs.osau.re/}project documentation} and tutorial available
    {{:https://robur-coop.github.io/miou/}here}.

    In order to launch the Miou scheduler and be able to launch and manage
    asynchronous tasks, the user must define a first entry point that must
    necessarily call {!val:run}:

    {[
      let () =
        Mkernel.(run []) @@ fun () ->
        let prm = Miou.async @@ fun () -> print_endline "Hello World!" in
        Mkernel.sleep 1_000_000_000;
        Miou.await_exn prm
    ]}

    All functions available through the Miou module work when implementing a
    unikernel {b except} [Miou.call], which wants to launch a task in parallel.
    [Miou.call] raises an exception because a unikernel only has one CPU.

    {2 Hypercalls.}

    Hypercalls are the only way for the unikernel to communicate with the
    outside world. A hypercall is a signal that we would like to obtain
    information from a specific external resource (such as a network interface
    or a block interface). This library offers several functions for emitting
    these hypercalls, which are then handled by the {i tender} and then by the
    host system.

    These hypercalls are standardised in a certain way and concern interactions
    with two types of resources:
    - the network interface, which emulates an Ethernet port
    - the block interface, which emulates a hard drive

    {3 Net interfaces.}

    A net interface is a TAP interface connected between your unikernel and the
    network of your host system. It is through this interface that you can
    communicate with your system's network and receive packets from it. The
    TCP/IP stack is also built from this interface.

    The user can read and write packets on such an interface. However, you need
    to understand how reading and writing behave when developing an application
    as a unikernel using Solo5/Unikraft.

    Writing a packet to the net interface is {b direct} and failsafe. In other
    words, we don't need to wait for anything to happen before writing to the
    net device (if an error occurs on your host system, the tender will fail —
    and by extension, so will your unikernel). So, from the scheduler's point of
    view, writing to the net device is atomic and is never suspended by the
    scheduler in order to have the opportunity to execute other tasks.

    However, this is not the case when reading on the net interface. You might
    expect to read packets, but they might not be available at the time you try
    to read them. [Mkernel] will make a first attempt at reading and if it
    fails, the scheduler will "suspend" the reading task (and everything that
    follows from it) to observe at another point in the life of unikernel
    whether a packet has just arrived.

    Reading on the net interface is currently the only operation where
    suspension is necessary. In this way, the scheduler can take the opportunity
    to perform other tasks if reading failed in the first place. It is at the
    next iteration of the scheduler (after it has executed at least one other
    task) that [Mkernel] will ask the tender if a packet has just arrived. If
    this is the case, the scheduler will resume the reading task, otherwise it
    will keep it in a suspended state until the next opportunity.

    {3 Block interfaces.}

    Block interfaces are different in that there is no expectation of whether or
    not there will be data. A block interface can be seen as content to which
    the user has one access per page (generally 4096 bytes). It can be read and
    written to. However, the read and write operation can take quite a long time
    — depending on the file system and your hardware on the host system.

    There are therefore two types of read/write. An atomic read/write and a
    scheduled read/write.

    An atomic read/write is an operation where you can be sure that it is not
    divisible (and that something else can be tried) and that the operation is
    currently being performed. Nothing else can be done until this operation has
    finished. It should be noted that once the operation has finished, the
    scheduler does not take the opportunity to do another task. It continues
    with what needs to be done after the read/write as you have implemented.

    This approach is interesting when you want to have certain invariants (in
    particular the state of the memory) that other tasks cannot alter despite
    such an operation. The problem is that this operation can take a
    considerable amount of time and we can't do anything else at the same time.

    This is why there is the other method, the read/write operation, which is
    suspended by default and will be performed when the scheduler has the best
    opportunity to do so — in other words, when it has nothing else to do.

    This type of operation can be interesting when reading/writing does not
    depend on assumptions and when these operations can be carried out at a
    later date without the current time at which the operation is carried out
    having any effect on the result. For example, scheduling reads on a block
    device that is read-only is probably more interesting than using atomic
    reads (whether the read is done at time [T0] or [T1], the result remains
    exactly the same). *)

type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

module Net : sig
  type t
  (** The type of network interfaces. *)

  type mac = private string
  (** The type of the hardware addres (MAC) of an ethernet interface. *)

  type cfg = { mac: mac; mtu: int }

  val read_bigstring : t -> ?off:int -> ?len:int -> bigstring -> int
  (** [read_bigstring t ?off ?len bstr] reads [len] (defaults to
      [Bigarray.Array1.dim bstr - off]) bytes from the net device [t], storing
      them in byte sequence [bstr], starting at position [off] (defaults to [0])
      in [bstr]. Return the number of bytes actually read.

      [read_bigstring] attempts an initial read. If it fails, we give the
      scheduler the opportunity to execute another task. The current task will
      be resumed as soon as bytes are available in the given net-device [t].

      @raise Invalid_argument
        if [off] and [len] do not designate a valid range of [bstr]. *)

  val read_bytes : t -> ?off:int -> ?len:int -> bytes -> int
  (** [read_bytes] is {!val:read_bigstring} but for [bytes]. However, this
      function uses an internal buffer (of a fixed size) which transmits the
      bytes from the net-device to the [byte] given by the user. If the [byte]
      given by the user is larger than the internal buffer, several actual reads
      are made.

      This means that a single [read_bytes] can give the scheduler several
      opportunities to execute other tasks.

      @raise Invalid_argument
        if [off] and [len] do not designate a valid range of [bstr]. *)

  (** {4 Writing to a net device according to the backend.}

      Depending on the backend used (Solo5/hvt or Unikraft & Solo5/virtio),
      writing to a TAP interface may involve an intermediate "queue" between the
      unikernel (which fills this queue) and the tender (which consumes this
      queue). This feature allows for a process on the tender side that attempts
      to write without interruption (and thus improves performance).

      In this case, unlike Solo5/hvt, writing is not necessarily effective
      between the unikernel and the TAP interface. However, this effectiveness
      also involves the tender's point of view, which is not taken into account
      (deliberately) in this documentation.

      Furthermore, from the point of view of the unikernel, OCaml and Miou (and
      only on that side), the write is effective. *)

  val write_bigstring : t -> ?off:int -> ?len:int -> bigstring -> unit
  (** [write_bigstring t ?off ?len bstr] writes [len] (defaults to
      [Bigarray.Array1.dim bstr - off]) bytes to the net device [t], taking them
      from byte sequence [bstr], starting at position [off] (defaults to [0]) in
      [bstr].

      [write_bigstring] is currently writing directly to the net device [t]. In
      other words, the write is effective and does not give the scheduler the
      opportunity to execute another task during the write. It is therefore an
      atomic operation. Writing cannot fail.

      @raise Invalid_argument
        if [off] and [len] do not designate a valid range of [bstr]. *)

  val write_string : t -> ?off:int -> ?len:int -> string -> unit
  (** Like {!val:write_bigstring}, but for [string]. *)

  val write_into : t -> len:int -> fn:(bigstring -> int) -> unit
  (** Depending on the backend used, an underlying allocation may be performed
      to write a new Ethernet frame. In the case of Unikraft, for example, we
      need to allocate a buffer that will be added to Unikraft's internal queue
      so that it can be written to the TAP interface. The same applies to Solo5
      and its {i virtio} support.

      [write_into] has the same characteristic as {!val:write_bigstring}, i.e.
      it is an atomic operation that does not give the scheduler the opportunity
      to execute another task.

      In this specific case, [write_into] is more useful than
      {!val:write_bigstring} because it prepares the allocation and lets the
      user write to the allocated buffer via the given [fn] function. *)

  val connect : string -> (t * cfg, [> `Msg of string ]) result
  (** [connect name] returns a net device according to the given [name]. It must
      correspond to the name given as an argument to the Solo5 tender. For
      example, if the invocation of our unikernel with Solo5 corresponds to:

      {[
        $ solo5-hvt --net:service=tap0 -- unikernel.hvt
      ]}

      The name of the block would be: ["service"]. *)
end

module Block : sig
  type t
  (** The type of block devices. *)

  val pagesize : t -> int
  (** [pagesize t] returns the number of bytes in a memory page, where "page" is
      a fixed length block, the unit for memory allocation and block-device
      mapping performed by the functions above. *)

  val atomic_read : t -> src_off:int -> ?dst_off:int -> bigstring -> unit
  (** [atomic_read t ~src_off ?dst_off bstr] reads data of [pagesize t] bytes
      into the buffer [bstr] (starting at byte [dst_off]) from the block device
      [t] at byte [src_off]. Always reads the full amount of [pagesize t] bytes
      ("short reads" are not possible).

      This operation is called {b atomic}, meaning that it is indivisible and
      irreducible. What's more, Miou can't do anything else (such as execute
      other tasks) until this operation has been completed.

      The advantage of this type of operation is that you can assume a precise
      state, not only of the memory but also of the block-device, which cannot
      change during the read.

      The disadvantage is that this operation can take a long time (and make
      your unikernel unavailable to all events for the duration of the
      operation) depending on the file system used by the host and the hardware
      used to store the block-device.

      @raise Invalid_argument
        if [src_off] is not a multiple of [pagesize t] or if the length of
        [bstr] is not equal to [pagesize t]. *)

  val atomic_write : t -> ?src_off:int -> dst_off:int -> bigstring -> unit
  (** [atomic_write t ~src_off ?dst_off bstr] writes data [pagesize t] bytes
      from the buffer [bstr] (at byte [dst_off]) to the block device identified
      by [t], starting at byte [src_off]. Data is either written in it's
      entirety or not at all ("short writes" are not possible).

      This operation is called {b atomic}, meaning that it is indivisible and
      irreducible. What's more, Miou can't do anything else (such as execute
      other tasks) until this operation has been completed.

      @raise Invalid_argument
        if [dst_off] is not a multiple of [pagesize t] or if the length of
        [bstr] is not equal to [pagesize t]. *)

  (** {3 Scheduled operations on block-devices.}

      As far as operations on scheduled block-devices are concerned, here's a
      description of when Miou performs these operations.

      As soon as Miou tries to observe possible events (such as the reception of
      a packet - see {!val:Net.read}), it also performs a (single) block-device
      operation. If Miou still has time (such as waiting for the end of a
      {!val:sleep}), it can perform several operations on the block-devices
      until it runs out of time.

      In short, operations on scheduled block-devices have the lowest priority.
      A unikernel can't go faster than the operations on waiting block-devices,
      so it's said to be I/O-bound on block-devices. *)

  val read : t -> src_off:int -> ?dst_off:int -> bigstring -> unit
  (** Like {!val:atomic_read}, but the operation is scheduled. That is, it's not
      actually done, but will be as soon as Miou gets the chance. *)

  val write : t -> ?src_off:int -> dst_off:int -> bigstring -> unit
  (** Like {!val:atomic_write}, but the operation is scheduled. That is, it's
      not actually done, but will be as soon as Miou gets the chance. *)

  val connect : string -> (t, [> `Msg of string ]) result
  (** [connect name] returns a block device according to the given [name]. It
      must correspond to the name given as an argument to the Solo5 tender. For
      example, if the invocation of our unikernel with Solo5 corresponds to:

      {[
        $ solo5-hvt --block:disk=file.txt -- unikernel.hvt
      ]}

      The name of the block would be: ["disk"]. *)
end

module Hook : sig
  type t
  (** Type of hooks.

      {b Unlike} Miou hooks, Mkernel's hooks only are executed when we perform
      the [yield] hypercall. In other words, these hooks only execute when
      waiting for a new external event.

      Such a hook can be useful for certain computations because the hook is
      only executed when truly random events occur: the occurrence of external
      events. *)

  val add : (unit -> unit) -> t
  (** [add fn] adds a new hook (a function) which will be executed at every new
      external events.

      A hook {b cannot} interact with the scheduler and, what's more, cannot use
      the effects associated with Miou. Miou's effects manager is not attached
      to it. If the given function raises an exception, the hook is {b deleted}.
      The user can remove the actual hook with {!val:remove}. It should be noted
      that if the user attempts to perform a Miou effect, an [Effect.Unhandled]
      exception is raised, which results in the hook being removed. *)

  val remove : t -> unit
  (** [remove h] removes the hook [h]. If [h] does not belong to the internal
      state of Mkernel, it raises an exception [Invalid_argument]. *)
end

val clock_monotonic : unit -> int
(** [clock_monotonic ()] returns monotonic time since an unspecified period in
    the past.

    The monotonic clock corresponds to the CPU time spent since the boot time.
    The monotonic clock cannot be relied upon to provide accurate results -
    unless great care is taken to correct the possible flaws. Indeed, if the
    unikernel is suspended (by the host system), the monotonic clock will no
    longer be aligned with the "real time elapsed" since the boot.

    This operation is {b atomic}. In other words, it does not give the scheduler
    the opportunity to execute another task. *)

val clock_wall : unit -> int
(** [clock_wall ()] returns wall clock in UTC since the UNIX epoch (1970-01-01).

    The wall clock corresponds to the host's clock. Indeed, each time
    [clock_wall ()] is called, a syscall/hypercall is made to get the host's
    clock. Compared to the monotonic clock, getting the host's clock may take
    some time.

    This operation is atomic. In other words, it does not give the scheduler the
    opportunity to execute another task. *)

val sleep : int -> unit
(** [sleep ns] blocks (suspends) the current task for [ns] nanoseconds. *)

(** {2 The first entry-point of an unikernels.}

    A unikernel is an application that can require several devices. {!val:net}
    devices ([tap] interfaces) and {!val:block} devices (files). These devices
    can be acquired by name and transformed (via {!val:map}.

    For example, a block device can be transformed into a file system, provided
    that the latter implementation uses the read and write operations associated
    with block devices (see {!module:Block}).

    {[
      let fs ~name =
        let open Mkernel in
        map [ block name ] @@ fun blk () -> Fat32.of_solo5_block blk
    ]}

    Mkernel acquires these devices, performs the transformations requested by
    the user and returns the results:

    {[
      let () =
        Mkernel.(run [ fs ~name:"disk.img" ]) @@ fun fat32 () ->
        let file_txt = Fat32.openfile fat32 "file.txt" in
        let finally () = Fat32.close file_txt in
        Fun.protect ~finally @@ fun () ->
        let line = Fat32.read_line file_txt in
        print_endline line
    ]}

    Finally, it executes the code given by the user. The user can therefore
    “build-up” complex systems (such as a TCP/IP stack from a net-device, or a
    file system from a block-device using the {!val:map} function). *)

type 'a arg
(** ['a arg] knows the type of an argument given to {!val:run}. *)

(** Multiple devices are passed to {!val:run} using a list-like syntax. For
    instance:

    {[
      let () =
        Mkernel.(run [ block "disk.img" ]) @@ fun _blk () ->
        print_endline "Hello World!"
    ]} *)
type ('k, 'res) devices =
  | [] : (unit -> 'res, 'res) devices
  | ( :: ) : 'a arg * ('k, 'res) devices -> ('a -> 'k, 'res) devices

val net : string -> (Net.t * Net.cfg) arg
(** [net name] is a net device which can be used by the {!module:Net} module.
    The given name must correspond to the argument given to the Solo5 tender or
    the qemu tender. For example, if the invocation of our unikernel with Solo5
    corresponds to:

    {[
      $ solo5-hvt --net:service=tap0 -- unikernel.hvt
    ]}

    The name of the block would be: ["service"].

    The user can specify the MAC address of the virtual interface the user
    wishes to use. Otherwise, Solo5 will choose a random one. It is given via
    the {!type:Net.cfg} value. *)

val block : string -> Block.t arg
(** [block name] is a block device which can be used by the {!module:Block}
    module. The given name must correspond to the argument given to the Solo5
    tender or the qemu tender. For example, if the invocation of our unikernel
    with Solo5 corresponds to:

    {[
      $ solo5-hvt --block:disk=file.txt -- unikernel.hvt
    ]}

    The name of the block would be: ["disk"]. *)

val map : 'f -> ('f, 'a) devices -> 'a arg
(** [map fn devices] provides a means for creating devices using other
    [devices]. For example, one might use a TCP/IP stack from a {!val:net}
    device:

    {[
      let tcpip ~name : Tcpip.t Mkernel.arg =
        Mkernel.(map [ net name ]) @@ fun ((net : Mkernel.Net.t), cfg) () ->
        Tcpip.of_net_device net
    ]} *)

val const : 'a -> 'a arg
(** [const v] always returns [v]. *)

val run :
  ?now:(unit -> int) -> ?g:Random.State.t -> ('a, 'b) devices -> 'a -> 'b
(** The first entry-point of an unikernel with Solo5 and Miou. *)
