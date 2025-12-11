let src = Logs.Src.create "mkernel"

module Log = (val Logs.src_log src : Logs.LOG)

type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

(* Unsafe part, C stubs. *)

type netif = int
type netbuf = int

external uk_netdev_init : (int[@untagged]) -> (netif[@untagged])
  = "unimplemented" "uk_netdev_init"
[@@noalloc]

external uk_netdev_mac : (netif[@untagged]) -> bytes -> unit
  = "unimplemented" "uk_netdev_mac"
[@@noalloc]

external uk_netdev_mtu : (netif[@untagged]) -> (int[@untagged])
  = "unimplemented" "uk_netdev_mtu"
[@@noalloc]

external _uk_netdev_stop : (netif[@untagged]) -> bool
  = "unimplemented" "uk_netdev_stop"
[@@noalloc]

external uk_netdev_is_queue_ready : (int[@untagged]) -> (bool[@untagged])
  = "unimplemented" "uk_netdev_is_queue_ready"
[@@noalloc]

external uk_netdev_rx :
     (netif[@untagged])
  -> bigstring
  -> (int[@untagged])
  -> (int[@untagged])
  -> bytes
  -> (int[@untagged]) = "unimplemented" "uk_netdev_rx"
[@@noalloc]

external uk_get_tx_buffer :
  (netif[@untagged]) -> (int[@untagged]) -> (netbuf[@untagged])
  = "unimplemented" "uk_get_tx_buffer"
[@@noalloc]

(* NOTE(dinosaure): allocation of a bigarray. *)
external uk_netbuf_to_bigarray : (netbuf[@untagged]) -> bigstring
  = "unimplemented" "uk_netbuf_to_bigarray"

external uk_netdev_tx :
     (netif[@untagged])
  -> (netbuf[@untagged])
  -> (int[@untagged])
  -> (int[@untagged]) = "unimplemented" "uk_netdev_tx"
[@@noalloc]

external uk_yield : (int[@untagged]) -> bytes -> unit
  = "unimplemented" "uk_yield"
[@@noalloc]

type block = int (* pointer *)
type token = int

external uk_block_init : int -> (block, string) result = "uk_block_init"
external uk_block_info : block -> bool * int * int64 = "uk_block_info"

external uk_block_async_read :
     block
  -> start:int64
  -> size:int
  -> bigstring
  -> off:int
  -> (token, string) result = "uk_block_async_read"

external uk_block_sync_read :
  block -> start:int64 -> size:int -> bigstring -> off:int -> bool
  = "uk_block_read"

external uk_block_async_write :
     block
  -> start:int64
  -> size:int
  -> bigstring
  -> off:int
  -> (token, string) result = "uk_block_async_write"

external uk_block_sync_write :
  block -> start:int64 -> size:int -> bigstring -> off:int -> bool
  = "uk_block_write"

external uk_complete_io : block -> token -> bool = "uk_complete_io"
external uk_max_tokens : unit -> int = "uk_max_tokens"
external uk_max_sectors_per_req : block -> int = "uk_max_sectors_per_req"

(* End of the unsafe part. Come back to the OCaml world! *)

external unsafe_get_int64_ne : bytes -> int -> int64 = "%caml_bytes_get64u"

let failwithf fmt = Format.kasprintf failwith fmt
let error_msgf fmt = Format.kasprintf (fun msg -> Error (`Msg msg)) fmt
let invalid_argf fmt = Format.kasprintf invalid_arg fmt

module Sem = struct
  type t = {
      mutable value: int
    ; mutable wakeups: int
    ; mutex: Miou.Mutex.t
    ; condition: Miou.Condition.t
  }

  let create value =
    {
      value
    ; wakeups= 0
    ; mutex= Miou.Mutex.create ()
    ; condition= Miou.Condition.create ()
    }

  let acquire t =
    Miou.Mutex.protect t.mutex @@ fun () ->
    while t.value <= 0 do
      Miou.Condition.wait t.condition t.mutex
    done;
    t.value <- t.value - 1

  let release t =
    Miou.Mutex.protect t.mutex @@ fun () ->
    t.value <- t.value + 1;
    Miou.Condition.signal t.condition
end

module Handles = struct
  type 'a t = { mutable contents: (int * 'a) list }

  let find tbl fd = List.assq fd tbl.contents

  let replace tbl fd v' =
    let contents =
      List.fold_left
        (fun acc (k, v) -> if k == fd then (k, v') :: acc else (k, v) :: acc)
        [] tbl.contents
    in
    tbl.contents <- contents

  let add tbl k v = tbl.contents <- (k, v) :: tbl.contents
  let remove tbl k = tbl.contents <- List.remove_assq k tbl.contents
  let create _ = { contents= [] }

  let append t k v =
    try
      let vs = find t k in
      replace t k (v :: vs)
    with Not_found -> add t k [ v ]

  let filter_map fn t =
    let contents = List.filter_map fn t.contents in
    t.contents <- contents
end

type elt = { time: int; syscall: Miou.syscall; mutable cancelled: bool }

module Heapq = Miou.Pqueue.Make (struct
  type t = elt

  let dummy = { time= 0; syscall= Obj.magic (); cancelled= false }
  let compare { time= a; _ } { time= b; _ } = Int.compare a b
end)

type domain = {
    netdevs: Miou.syscall list Handles.t
  ; blkdevs: Miou.syscall list Handles.t
  ; sleepers: Heapq.t
}

let domain =
  {
    netdevs= Handles.create 0x100
  ; blkdevs= Handles.create 0x100
  ; sleepers= Heapq.create ()
  }

let blocking_block_io uid tid =
  let sid = (uid lsl 6) lor tid in
  let syscall = Miou.syscall () in
  let fn () = Handles.append domain.blkdevs sid syscall in
  Miou.suspend ~fn syscall

module Block = struct
  type t = {
      handle: block
    ; uid: int
    ; read_only: bool
    ; pagesize: int
    ; number_of_pages: int64
    ; max_pages_per_req: int
    ; sem: Sem.t
  }

  let pagesize { pagesize; _ } = 1 lsl pagesize

  let length { pagesize; number_of_pages; _ } =
    pagesize * Int64.to_int number_of_pages

  let unsafe_ctz n =
    let t = ref 1 in
    let r = ref 0 in
    while n land !t = 0 do
      t := !t lsl 1;
      incr r
    done;
    !r

  let connect name =
    try
      let uid = int_of_string name in
      match uk_block_init uid with
      | Ok handle ->
          let read_only, pagesize, number_of_pages = uk_block_info handle in
          let pagesize = unsafe_ctz pagesize in
          (* NOTE(dinosaure): it seems that [uk_max_sectors_per_req] returns a
             value which is computed only by [uk_block_init]. At this stage, it
             seems to be a constant and we can bring it into our [t] record. *)
          let max_pages_per_req = uk_max_sectors_per_req handle in
          let sem = Sem.create (uk_max_tokens ()) in
          Ok
            {
              handle
            ; uid
            ; read_only
            ; pagesize
            ; number_of_pages
            ; max_pages_per_req
            ; sem
            }
      | Error msg -> Error (`Msg msg)
    with _ -> error_msgf "Invalid blockdev interface (must be a number)"

  let async_unsafe ~fn t ~src_off ~dst_off dst =
    Sem.acquire t.sem;
    let size = Bigarray.Array1.dim dst - dst_off in
    let size = Int.min (t.max_pages_per_req * (1 lsl t.pagesize)) size in
    let size = size lsr t.pagesize in
    (* TODO(dinosaure): we should directly use an [int]. *)
    let start = Int64.of_int (src_off lsr t.pagesize) in
    match fn t.handle ~start ~size dst ~off:dst_off with
    | Ok tid ->
        blocking_block_io t.uid tid;
        let ok = uk_complete_io t.handle tid in
        Sem.release t.sem;
        if not ok then
          failwithf "Mkernel.Block.operation: operation not completed"
    | Error msg ->
        Sem.release t.sem;
        failwithf "Mkernel.Block.operation: %s" msg

  (* TODO(dinosaure): synchronous operations on unikraft is not yet available. *)
  let unsafe ~fn t ~src_off ~dst_off dst =
    let size = Bigarray.Array1.dim dst - dst_off in
    let size = Int.min (t.max_pages_per_req * t.pagesize) size in
    let size = size lsr t.pagesize in
    (* TODO(dinosaure): we should directly use an [int]. *)
    let start = Int64.of_int (src_off lsr t.pagesize) in
    let ok = fn t.handle ~start ~size dst ~off:dst_off in
    if not ok then failwithf "Mkernel.Block.operation: error"

  let _read kind t ~src_off ?(dst_off = 0) dst =
    if dst_off < 0 || dst_off > Bigarray.Array1.dim dst - (1 lsl t.pagesize)
    then
      invalid_argf
        "Mkernel.Block.read: [dst_off] (%d) or length (%d) of the destination \
         bigarray are wrong."
        dst_off (Bigarray.Array1.dim dst);
    if src_off land ((1 lsl t.pagesize) - 1) != 0 then
      invalid_argf
        "Mkernel.Block.read: [src_off] must be aligned to the pagesize (%d)"
        (1 lsl t.pagesize);
    match kind with
    | `Sync -> unsafe ~fn:uk_block_sync_read t ~src_off ~dst_off dst
    | `Async -> async_unsafe ~fn:uk_block_async_read t ~src_off ~dst_off dst

  let _write kind t ?(src_off = 0) ~dst_off src =
    if src_off < 0 || src_off > Bigarray.Array1.dim src - (1 lsl t.pagesize)
    then
      invalid_argf
        "Mkernel.Block.write: [src_off] (%d) or length (%d) of the destination \
         bigarray are wrong."
        dst_off (Bigarray.Array1.dim src);
    if dst_off land ((1 lsl t.pagesize) - 1) != 0 then
      invalid_argf
        "Mkernel.Block.write: [dst_off] must be aligned to the pagesize (%d)"
        (1 lsl t.pagesize);
    match kind with
    | `Sync -> unsafe ~fn:uk_block_sync_write t ~src_off ~dst_off src
    | `Async -> async_unsafe ~fn:uk_block_async_write t ~src_off ~dst_off src

  let atomic_read t ~src_off ?(dst_off = 0) bstr =
    _read `Sync t ~src_off ~dst_off bstr

  let atomic_write t ?(src_off = 0) ~dst_off bstr =
    _write `Sync t ~src_off ~dst_off bstr

  let read t ~src_off ?(dst_off = 0) bstr =
    _read `Async t ~src_off ~dst_off bstr

  let write t ?(src_off = 0) ~dst_off bstr =
    _write `Async t ~src_off ~dst_off bstr
end

let blocking_net_read uid =
  let syscall = Miou.syscall () in
  let fn () = Handles.append domain.netdevs uid syscall in
  Miou.suspend ~fn syscall

module Net = struct
  type t = { netif: netif; uid: int }
  type mac = string
  type cfg = { mac: mac; mtu: int }

  let connect name =
    try
      let uid = int_of_string name in
      let netif = uk_netdev_init uid in
      if netif == -1 then error_msgf "Impossible to acquire netdev %d" uid
      else begin
        let mac = Bytes.create 6 in
        uk_netdev_mac netif mac;
        let mac = Bytes.unsafe_to_string mac in
        let mtu = uk_netdev_mtu netif in
        let cfg = { mac; mtu } in
        Ok ({ netif; uid }, cfg)
      end
    with _ -> error_msgf "Invalid netdev interface (must be a number)"

  let read t ~off ~len bstr =
    let rec go read_size =
      match uk_netdev_is_queue_ready t.uid with
      | false -> blocking_net_read t.uid; go read_size
      | true ->
          let ret = uk_netdev_rx t.netif bstr off len read_size in
          if ret < 0 then failwith "Mkernel.Net.read"
          else Int64.to_int (unsafe_get_int64_ne read_size 0)
    in
    go (Bytes.make 8 '\000')

  let read_bigstring t ?(off = 0) ?len bstr =
    let len =
      match len with Some len -> len | None -> Bigarray.Array1.dim bstr - off
    in
    if len < 0 || off < 0 || off > Bigarray.Array1.dim bstr - len then
      invalid_arg "Mkernel.Net.read_bigstring: out of bounds";
    read t ~off ~len bstr

  let read_bytes _t ?off:_ ?len:_ _buf = assert false

  (* NOTE(dinosaure): here, we follow also what Solo5 provides. If we fail to
     write an Ethernet frame, we should exit as Solo5 does when [solo5-hvt] is
     not able to write anything into the TAP interface.

     The logic behind Unikraft is bit more complex because it involves an
     allocation ([malloc()] on the C side which can fails. We can easily say
     that if we are not able to allocate on the C heap, we are probably doomed.
     As Solo5 and [solo5-hvt], we just fail. *)

  let write_into t ~len ~fn =
    let netbuf = uk_get_tx_buffer t.netif len in
    if netbuf == -1 then
      failwith "Mkernel.Net.write: impossible to get a net buffer";
    let bstr = uk_netbuf_to_bigarray netbuf in
    let len = fn bstr in
    if len > Bigarray.Array1.dim bstr then
      invalid_arg "Mkernel.Net.write: filler out of bounds";
    let ret = uk_netdev_tx t.netif netbuf len in
    if ret == -1 then
      failwith "Mkernel.Net.write: impossible to write into the given netdev"

  let write_bigstring t ?(off = 0) ?len bstr =
    let default = Bigarray.Array1.dim bstr - off in
    let len = Option.value ~default len in
    if len < 0 || off < 0 || off > Bigarray.Array1.dim bstr - len then
      invalid_arg "Mkernel.Net.write_bigstring: out of bounds";
    let bstr = Bigarray.Array1.sub bstr off len in
    let fn bstr' =
      Bigarray.Array1.(blit bstr (sub bstr' 0 len));
      len
    in
    write_into t ~len ~fn

  let write_string _t ?off:_ ?len:_ _str = assert false
end

module Hook = struct
  type t = (unit -> unit) Miou.Sequence.node

  let hooks = Miou.Sequence.create ()
  let add fn = Miou.Sequence.(add Left) hooks fn
  let remove node = Miou.Sequence.remove node
  let run () = Miou.Sequence.iter ~f:(fun fn -> fn ()) hooks
end

external clock_monotonic : unit -> (int[@untagged])
  = "unimplemented" "ukplat_monotonic_clock"
[@@noalloc]

external clock_wall : unit -> (float[@unboxed])
  = "unimplemented" "caml_sys_time_unboxed"
[@@noalloc]

let clock_wall () =
  let by_sec = clock_wall () in
  Float.to_int (by_sec *. 1e9)

let now = ref clock_monotonic

let sleep until =
  let syscall = Miou.syscall () in
  let elt = { time= !now () + until; syscall; cancelled= false } in
  Heapq.insert elt domain.sleepers;
  Miou.suspend syscall

(* poll part of Mkernel *)

let rec sleeper () =
  match Heapq.find_min_exn domain.sleepers with
  | exception Heapq.Empty -> None
  | { cancelled= true; _ } ->
      Heapq.delete_min_exn domain.sleepers;
      sleeper ()
  | { time; _ } -> Some time

let in_the_past t = t == 0 || t <= !now ()

let rec collect_sleepers domain signals =
  match Heapq.find_min_exn domain.sleepers with
  | exception Heapq.Empty -> signals
  | { cancelled= true; _ } ->
      Heapq.delete_min_exn domain.sleepers;
      collect_sleepers domain signals
  | { time; syscall; _ } when in_the_past time ->
      Heapq.delete_min_exn domain.sleepers;
      collect_sleepers domain (Miou.signal syscall :: signals)
  | _ -> signals

let clean domain uids =
  let to_delete syscall =
    let uid = Miou.uid syscall in
    List.exists (fun uid' -> uid == uid') uids
  in
  let fn0 (handle, syscalls) =
    match List.filter (Fun.negate to_delete) syscalls with
    | [] -> None
    | syscalls -> Some (handle, syscalls)
  in
  let fn1 (({ syscall; _ } : elt) as elt) =
    if to_delete syscall then elt.cancelled <- true
  in
  Handles.filter_map fn0 domain.netdevs;
  Heapq.iter fn1 domain.sleepers

let yield_result = Bytes.create 17

let yield domain deadline =
  Log.debug (fun m -> m "yield %dns" (deadline - !now ()));
  uk_yield deadline yield_result;
  match Bytes.get yield_result 0 with
  | '\000' -> None
  | '\001' ->
      let uid = Bytes.get_int64_ne yield_result 1 in
      let uid = Int64.to_int uid in
      let signals = Handles.find domain.netdevs uid in
      Handles.remove domain.netdevs uid;
      Some signals
  | '\002' ->
      (* TODO(dinosaure): [tid] fits into 6 bits and [uid] fits into 5 bits.
         We can easily use a simple [int] to store these informations instead of
         using an [Int64]. *)
      let uid = Bytes.get_int64_ne yield_result 1 in
      let uid = Int64.to_int uid in
      let tid = Bytes.get_int64_ne yield_result 9 in
      let tid = Int64.to_int tid in
      let sid = (uid lsl 6) lor tid in
      let signals = Handles.find domain.blkdevs sid in
      Handles.remove domain.blkdevs sid;
      Some signals
  | _ -> assert false

type waiting = Infinity | Yield | Sleep of int

let wait_for ~block =
  match (sleeper (), block) with
  | None, true -> Infinity
  | (None | Some _), false -> Yield
  | Some point, true ->
      let until = point - !now () in
      if until < 0 then Yield else Sleep until

(* The behaviour of our select is a little different from what we're used to
   seeing. Currently, only a read on a net device can produce a necessary
   suspension (the reception of packets on the network).

   However, a special case concerns the block device. Reading and writing to it
   can take time. It can be interesting to suspend these actions and actually
   do them when we should be waiting (as long as a sleeper is active or until
   an event appears).

   The idea is to suspend these actions so that we can take the opportunity to
   do something else and actually do them when we have the time to do so: when
   Miou has no more tasks to do and when we don't have any network events to
   manage.

   The implication of this would be that our unikernels would be limited by I/O
   on block devices. They won't be able to go any further than reading and
   writing to block devices. As far as I/O on net devices is concerned, we are
   only limited by the OCaml code that has to handle incoming packets. Packet
   writing, on the other hand, is direct. *)

let continue ~retry signals = function
  | Some syscalls -> List.rev_append (List.map Miou.signal syscalls) signals
  | None -> retry signals

let select ~block cancelled_syscalls =
  clean domain cancelled_syscalls;
  let rec go (signals : Miou.signal list) =
    match wait_for ~block with
    | Infinity ->
        (* Miou tells us we can wait forever ([block = true]) and we have no
           sleepers. So we're going to: take action on the block devices and ask
           Solo5 if we need to manage an event. If we have an event after the
           action on the block device ([handles != 0]), we stop and send the
           signals to Miou. If not, we take the opportunity to possibly go
           further. *)
        let deadline = max_int in
        let (signals' : Miou.syscall list option) = yield domain deadline in
        Hook.run ();
        continue ~retry:go signals signals'
    | Yield ->
        (* Miou still has work to do but asks if there are any events. We ask
           Solo5 if there are any and return the possible signals to Miou. *)
        (* handles := miou_solo5_yield 0; *)
        (* It should be noted here that we can set the Miou scheduler as [lwt].
           It also seems that from a performance point of view, it is more
           interesting to "let" Miou finish all tasks at suspension points
           rather than observing events regularly. This decreases the
           availability of the unikernel but improves performance.

           One option might be to force event monitoring according to the [utcp]
           timer (every 100ms) in order to increase availability without
           significantly impacting performance. TODO *)
        signals
    | Sleep until ->
        (* We have a sleeper that is still active and will have to wait a while
           before consuming it. In the meantime, we take action on the block
           devices and repeat our [select] if Solo5 tells us that there are no
           events ([handle == 0]). *)
        let deadline = clock_monotonic () + until in
        let signals' = yield domain deadline in
        Hook.run ();
        continue ~retry:go signals signals'
  in
  let signals = [] in
  let signals = go signals in
  collect_sleepers domain signals

let events _domain = { Miou.interrupt= ignore; select; finaliser= ignore }

type 'a arg =
  | Net : string -> (Net.t * Net.cfg) arg
  | Block : string -> Block.t arg
  | Map : ('f, 'a) devices * 'f -> 'a arg
  | Const : 'a -> 'a arg

and ('k, 'res) devices =
  | [] : (unit -> 'res, 'res) devices
  | ( :: ) : 'a arg * ('k, 'res) devices -> ('a -> 'k, 'res) devices

let net name = Net name
let block name = Block name
let map fn args = Map (args, fn)
let const v = Const v

let rec ctor : type a. a arg -> a = function
  | Net device -> begin
      match Net.connect device with
      | Ok (t, cfg) -> (t, cfg)
      | Error (`Msg msg) -> failwithf "%s." msg
    end
  | Block device -> begin
      match Block.connect device with
      | Ok t -> t
      | Error (`Msg msg) -> failwithf "%s." msg
    end
  | Const v -> v
  | Map (args, fn) -> go (fun fn -> fn ()) args fn

and go : type k res. ((unit -> res) -> res) -> (k, res) devices -> k -> res =
 fun run -> function
  | [] -> fun fn -> run fn
  | arg :: devices ->
      let v = ctor arg in
      fun f ->
        let r = f v in
        go run devices r

let run ?now:clock ?g devices fn =
  Option.iter (fun fn -> now := fn) clock;
  Miou.run ~events ~domains:0 ?g @@ fun () ->
  let run fn = fn () in
  go run devices fn
