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
    device (if an error occurs on your host system, the Solo5 tender will fail
    \- and by extension, so will your unikernel). So, from the scheduler's point
    of view, writing to the net device is atomic and is never suspended by the
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
    opportunity to do so - in other words, when it has nothing else to do.

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
    waiting for a packet - {!val:Net.read} - or reading/writing a block device).
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
  val write_string : t -> ?off:int -> ?len:int -> string -> unit
  val connect : string -> (t * cfg, [> `Msg of string ]) result
end

module Block : sig
  type t

  val pagesize : t -> int
  val atomic_read : t -> off:int -> bigstring -> unit
  val atomic_write : t -> off:int -> bigstring -> unit
  val read : t -> off:int -> bigstring -> unit
  val write : t -> off:int -> bigstring -> unit
  val connect : string -> (t, [> `Msg of string ]) result
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

type 'a arg

type ('k, 'res) devices =
  | [] : (unit -> 'res, 'res) devices
  | ( :: ) : 'a arg * ('k, 'res) devices -> ('a -> 'k, 'res) devices

val net : string -> (Net.t * Net.cfg) arg
val block : string -> Block.t arg
val opt : 'a arg -> 'a option arg
val map : 'f -> ('f, 'a) devices -> 'a arg
val dft : 'a -> 'a arg -> 'a arg
val const : 'a -> 'a arg
val run : ?g:Random.State.t -> ('a, 'b) devices -> 'a -> 'b
