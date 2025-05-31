(** A simple scheduler for Solo5 in OCaml.

    Solo5 has 5 hypercalls, 2 for reading and writing to a net device and 2 for
    reading and writing to a block device. The last hypercall stops the program.
    This library is an OCaml scheduler (based on Miou) that allows you to
    interact with these devices. However, the behaviour of these hypercalls
    needs to be specified in order to understand how to use them properly when
    it comes to creating a unikernel in OCaml.

    {2 Net devices.}

    A net device is a TAP interface connected between your unikernel and the
    network of your host system. It is through this device that you can
    communicate with your system's network and receive packets from it. The
    TCP/IP stack is also built from this device.

    The user can read and write packets on such a device. However, you need to
    understand how reading and writing behave when developing an application as
    a unikernel using Solo5.

    Writing a packet to the net device is direct and failsafe. In other words,
    we don't need to wait for anything to happen before writing to the net
    device (if an error occurs on your host system, the Solo5 tender will fail —
    and by extension, so will your unikernel). So, from the scheduler's point of
    view, writing to the net device is atomic and is never suspended by the
    scheduler in order to have the opportunity to execute other tasks.

    However, this is not the case when reading the net device. You might expect
    to read packages, but they might not be available at the time you try to
    read them. [Miou_solo5] will make a first attempt at reading and if it
    fails, the scheduler will "suspend" the reading task (and everything that
    follows from it) to observe at another point in the life of unikernel
    whether a packet has just arrived.

    Reading the net device is currently the only operation where suspension is
    necessary. In this way, the scheduler can take the opportunity to perform
    other tasks if reading failed in the first place. It is at the next
    iteration of the scheduler (after it has executed at least one other task)
    that [Miou_solo5] will ask the tender if a packet has just arrived. If this
    is the case, the scheduler will resume the read task, otherwise it will keep
    it in a suspended state until the next iteration.

    {2 Block devices.}

    Block devices are different in that there is no expectation of whether or
    not there will be data. A block device can be seen as content to which the
    user has one access per page (generally 4096 bytes). It can be read and
    written to. However, the read and write operation can take quite a long time
    \- depending on the file system and your hardware on the host system.

    There are therefore two types of read/write. An atomic read/write and a
    scheduled read/write.

    An atomic read/write is an operation where you can be sure that it is not
    divisible (and that something else can be tried) and that the operation is
    currently being performed. Nothing else can be done until this operation has
    finished. It should be noted that once the operation has finished, the
    scheduler does not take the opportunity to do another task. It continues
    with what needs to be done after the read/write as you have implemented in
    OCaml.

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
    reads (whether the read is done at time [T0] or [T1], the result remains the
    same).

    {2 The scheduler.}

    [Miou_solo5] is based on the Miou scheduler. Basically, this scheduler
    allows the user to perform tasks in parallel. However, Solo5 does {b not}
    have more than a single core. Parallel tasks are therefore {b unavailable}
    \- in other words, the user should {b not} use [Miou.call] but only
    [Miou.async].

    Finally, the scheduler works in such a way that scheduled read/write
    operations on a block device are relegated to the lowest priority tasks.
    However, this does not mean that [Miou_solo5] is a scheduler that tries to
    complete as many tasks as possible before reaching an I/O operation (such as
    waiting for a packet — {!val:Net.read} — or reading/writing a block device).
    Miou and [Miou_solo5] aim to increase the availability of an application: in
    other words, as soon as there is an opportunity to execute a task other than
    the current one, Miou will take it.

    In this case, all the operations (except atomic ones) present in this module
    give Miou the opportunity to suspend the current task and execute another
    task. *)

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

  val write_bigstring : t -> ?off:int -> ?len:int -> bigstring -> unit
  (** [write_bigstring t ?off ?len bstr] writes [len] (defaults to
      [Bigarray.Array1.dim bstr - off]) bytes to the net device [t], taking them
      from byte sequence [bstr], starting at position [off] (defaults to [0]) in
      [bstr].

      [write_bigstring] is currently writing directly to the net device [t].
      Writing cannot fail.

      @raise Invalid_argument
        if [off] and [len] do not designate a valid range of [bstr]. *)

  val write_string : t -> ?off:int -> ?len:int -> string -> unit
  (* Like {!val:write_bigstring}, but for [string]. *)

  val connect : string -> (t * cfg, [> `Msg of string ]) result
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

  val write : t -> src_off:int -> ?dst_off:int -> bigstring -> unit
  (** Like {!val:atomic_write}, but the operation is scheduled. That is, it's
      not actually done, but will be as soon as Miou gets the chance. *)

  val connect : string -> (t, [> `Msg of string ]) result
  (** [connect name] returns a block device according to the given [name]. It
      must correspond to the name given as an argument to the Solo5 tender. For
      example, if the invocation of our unikernel corresponds to:

      {[
        $ solo5-hvt --block:disk=file.txt -- unikernel.hvt
      ]}

      The name of the block would be: ["disk"]. *)
end

module Hook : sig
  type t
  (** Type of hooks.

      Unlike Miou hooks, Miou_solo5's hooks only are executed when we perform
      the [solo5_yield] hypercall. In other words, these hooks only execute when
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
      state of Miou_solo5, it raises an exception [Invalid_argument]. *)
end

external clock_monotonic : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_monotonic"
[@@noalloc]
(** [clock_monotonic ()] returns monotonic time since an unspecified period in
    the past.

    The monotonic clock corresponds to the CPU time spent since the boot time.
    The monotonic clock cannot be relied upon to provide accurate results -
    unless great care is taken to correct the possible flaws. Indeed, if the
    unikernel is suspended (by the host system), the monotonic clock will no
    longer be aligned with the "real time elapsed" since the boot.

    This operation is {b atomic}. In other words, it does not give the scheduler
    the opportunity to execute another task. *)

external clock_wall : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_wall"
[@@noalloc]
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
        let open Miou_solo5 in
        map [ block name ] @@ fun blk () -> Fat32.of_solo5_block blk
    ]}

    Miou_solo5 acquires these devices, performs the transformations requested by
    the user and returns the results:

    {[
      let () =
        Miou_solo5.(run [ fs ~name:"disk.img" ]) @@ fun fat32 () ->
        let file_txt = Fat32.openfile fat32 "file.txt" in
        let finally () = Fat32.close file_txt in
        Fun.protect ~finally @@ fun () ->
        let line = Fat32.read_line file_txt in
        print_endline line
    ]}

    Finally, it executes the code given by the user. The user can therefore
    “build-up” complex systems (such as a TCP/IP stack from a net-device, or a
    file system from a block-device using the {!val:map} function).

    {2 Miou_solo5 and build-systems.}

    Miou_solo5 can be compiled as a simple executable to run on the host system
    or a unikernel with the Solo5 toolchain. As for the executable produced, the
    latter produces a “manifest” (in JSON format) describing the devices
    required by the unikernel. This manifest is {b required} to compile the
    unikernel.

    It is therefore possible to:
    + produce the executable
    + generate the [manifest.json] via the produced executable
    + generate the unikernel using the same code that generated the
      [manifest.json], but with the Solo5 toolchain. *)

type 'a arg
(** ['a arg] knows the type of an argument given to {!val:run}. *)

(** Multiple devices are passed to {!val:run} using a list-like syntax. For
    instance:

    {[
      let () =
        Miou_solo5.(run [ block "disk.img" ]) @@ fun _blk () ->
        print_endline "Hello World!"
    ]} *)
type ('k, 'res) devices =
  | [] : (unit -> 'res, 'res) devices
  | ( :: ) : 'a arg * ('k, 'res) devices -> ('a -> 'k, 'res) devices

val net : string -> (Net.t * Net.cfg) arg
(** [net name] is a net device which can be used by the {!module:Net} module.
    The given name must correspond to the argument given to the Solo5 tender.
    For example, if the invocation of our unikernel corresponds to:

    {[
      $ solo5-hvt --net:service=tap0 -- unikernel.hvt
    ]}

    The name of the block would be: ["service"].

    The user can specify the MAC address of the virtual interfac the user wishes
    to use. Otherwise, Solo5 will choose a random one. It is given via the
    {!type:Net.cfg} value. *)

val block : string -> Block.t arg
(** [block name] is a block device which can be used by the {!module:Block}
    module. The given name must correspond to the argument given to the Solo5
    tender. For example, if the invocation of our unikernel corresponds to:

    {[
      $ solo5-hvt --block:disk=file.txt -- unikernel.hvt
    ]}

    The name of the block would be: ["disk"]. *)

val map : 'f -> ('f, 'a) devices -> 'a arg
(** [map fn devices] provides a means for creating devices using other
    [devices]. For example, one might use a TCP/IP stack from a {!val:net}
    device:

    {[
      let tcpip ~name : Tcpip.t Miou_solo5.arg =
        Miou_solo5.(map [ net name ])
        @@ fun ((net : Miou_solo5.Net.t), cfg) () -> Tcpip.of_net_device net
    ]} *)

val const : 'a -> 'a arg
(** [const v] always returns [v]. *)

val run : ?g:Random.State.t -> ('a, 'b) devices -> 'a -> 'b
(** The first entry-point of an unikernel with Solo5 and Miou. *)
