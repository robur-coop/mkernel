let src = Logs.Src.create "miou.solo5"

module Log = (val Logs.src_log src : Logs.LOG)

type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

external bigstring_get_uint8 : bigstring -> int -> int = "%caml_ba_ref_1"

external bigstring_set_uint8 : bigstring -> int -> int -> unit
  = "%caml_ba_set_1"

external bigstring_get_int32_ne : bigstring -> int -> int32
  = "%caml_bigstring_get32"

external bigstring_set_int32_ne : bigstring -> int -> int32 -> unit
  = "%caml_bigstring_set32"

let bigstring_blit_to_bytes bstr ~src_off dst ~dst_off ~len =
  let len0 = len land 3 in
  let len1 = len lsr 2 in
  for i = 0 to len1 - 1 do
    let i = i * 4 in
    let v = bigstring_get_int32_ne bstr (src_off + i) in
    Bytes.set_int32_ne dst (dst_off + i) v
  done;
  for i = 0 to len0 - 1 do
    let i = (len1 * 4) + i in
    let v = bigstring_get_uint8 bstr (src_off + i) in
    Bytes.set_uint8 dst (dst_off + i) v
  done

let bigstring_blit_from_string src ~src_off dst ~dst_off ~len =
  let len0 = len land 3 in
  let len1 = len lsr 2 in
  for i = 0 to len1 - 1 do
    let i = i * 4 in
    let v = String.get_int32_ne src (src_off + i) in
    bigstring_set_int32_ne dst (dst_off + i) v
  done;
  for i = 0 to len0 - 1 do
    let i = (len1 * 4) + i in
    let v = String.get_uint8 src (src_off + i) in
    bigstring_set_uint8 dst (dst_off + i) v
  done

(* Unsafe part, C stubs. *)

external miou_solo5_net_acquire : string -> bytes -> bytes -> bytes -> int
  = "unimplemented" "miou_solo5_net_acquire"
[@@noalloc]

external miou_solo5_net_read :
     (int[@untagged])
  -> bigstring
  -> (int[@untagged])
  -> (int[@untagged])
  -> bytes
  -> (int[@untagged]) = "unimplemented" "miou_solo5_net_read"
[@@noalloc]

external miou_solo5_net_write :
     (int[@untagged])
  -> (int[@untagged])
  -> (int[@untagged])
  -> bigstring
  -> (int[@untagged]) = "unimplemented" "miou_solo5_net_write"
[@@noalloc]

external miou_solo5_block_acquire : string -> bytes -> bytes -> bytes -> int
  = "unimplemented" "miou_solo5_block_acquire"
[@@noalloc]

external miou_solo5_block_read :
     (int[@untagged])
  -> src_off:(int[@untagged])
  -> dst_off:(int[@untagged])
  -> (int[@untagged])
  -> bigstring
  -> (int[@untagged]) = "unimplemented" "miou_solo5_block_read"
[@@noalloc]

external miou_solo5_block_write :
     (int[@untagged])
  -> src_off:(int[@untagged])
  -> dst_off:(int[@untagged])
  -> (int[@untagged])
  -> bigstring
  -> (int[@untagged]) = "unimplemented" "miou_solo5_block_write"
[@@noalloc]

external miou_solo5_malloc_trim : unit -> bool
  = "unimplemented" "miou_solo5_malloc_trim"
[@@noalloc]

(* End of the unsafe part. Come back to the OCaml world! *)

external unsafe_get_int64_ne : bytes -> int -> int64 = "%caml_bytes_get64u"

let invalid_argf fmt = Format.kasprintf invalid_arg fmt
let failwithf fmt = Format.kasprintf failwith fmt
let error_msgf fmt = Format.kasprintf (fun msg -> Error (`Msg msg)) fmt

module Block_direct = struct
  type t = { handle: int; pagesize: int; len: int }

  let pagesize { pagesize; _ } = pagesize
  let length { len; _ } = len

  let connect name =
    let handle = Bytes.make 8 '\000' in
    let len = Bytes.make 8 '\000' in
    let pagesize = Bytes.make 8 '\000' in
    match miou_solo5_block_acquire name handle len pagesize with
    | 0 ->
        let handle = Int64.to_int (Bytes.get_int64_ne handle 0) in
        let len = Int64.to_int (Bytes.get_int64_ne len 0) in
        let pagesize = Int64.to_int (Bytes.get_int64_ne pagesize 0) in
        Ok { handle; pagesize; len }
    | errno ->
        error_msgf "Impossible to connect the block-device %s (%d)" name errno

  let unsafe_read t ~src_off ?(dst_off = 0) dst =
    match miou_solo5_block_read t.handle ~src_off ~dst_off t.pagesize dst with
    | 0 -> ()
    | 2 -> invalid_arg "Mkernel.Block.read"
    | _ -> assert false (* AGAIN | UNSPEC *)

  let atomic_read t ~src_off ?(dst_off = 0) dst =
    if dst_off < 0 || dst_off > Bigarray.Array1.dim dst - t.pagesize then
      invalid_argf
        "Mkernel.Block.atomic_read: [dst_off] (%d) or length (%d) of the \
         destination bigarray are wrong."
        dst_off (Bigarray.Array1.dim dst);
    if src_off land (t.pagesize - 1) != 0 then
      invalid_argf
        "Mkernel.Block.atomic_read: [src_off] must be aligned to the pagesize \
         (%d)"
        t.pagesize;
    unsafe_read t ~src_off ~dst_off dst

  let unsafe_write t ?(src_off = 0) ~dst_off src =
    match miou_solo5_block_write t.handle ~src_off ~dst_off t.pagesize src with
    | 0 -> ()
    | 2 -> invalid_arg "Mkernel.Block.write"
    | _ -> assert false (* AGAIN | UNSPEC *)

  let atomic_write t ?(src_off = 0) ~dst_off src =
    if src_off < 0 || src_off > Bigarray.Array1.dim src - t.pagesize then
      invalid_argf
        "Mkernel.Block.atomic_write: [src_off] (%d) or length (%d) of the \
         destination bigarray are wrong."
        dst_off (Bigarray.Array1.dim src);
    if dst_off land (t.pagesize - 1) != 0 then
      invalid_argf
        "Mkernel.Block.atomic_write: [dst_off] must be aligned to the pagesize \
         (%d)"
        t.pagesize;
    unsafe_write t ~src_off ~dst_off src
end

module Handles = struct
  type 'a t = { mutable contents: (int * 'a) list }

  let find tbl fd = List.assq fd tbl.contents

  let replace tbl fd v' =
    let contents =
      List.fold_left
        (fun acc (k, v) -> if k = fd then (k, v') :: acc else (k, v) :: acc)
        [] tbl.contents
    in
    tbl.contents <- contents

  let add tbl k v = tbl.contents <- (k, v) :: tbl.contents
  let create _ = { contents= [] }

  let append t k v =
    try
      let vs = find t k in
      replace t k (v :: vs)
    with Not_found -> add t k [ v ]

  let fold_left_map fn acc t =
    let acc, contents = List.fold_left_map fn acc t.contents in
    t.contents <- contents;
    acc

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

type action = Rd of arguments | Wr of arguments

and arguments = {
    t: Block_direct.t
  ; bstr: bigstring
  ; src_off: int
  ; dst_off: int
  ; syscall: Miou.syscall
  ; mutable cancelled: bool
}

type domain = {
    handles: Miou.syscall list Handles.t
  ; sleepers: Heapq.t
  ; blocks: action Queue.t
}

let domain =
  {
    handles= Handles.create 0x100
  ; sleepers= Heapq.create ()
  ; blocks= Queue.create ()
  }

let blocking_read fd =
  let syscall = Miou.syscall () in
  let fn () = Handles.append domain.handles fd syscall in
  Miou.suspend ~fn syscall

module Net = struct
  type t = int
  type mac = string
  type cfg = { mac: mac; mtu: int }

  let connect name =
    let handle = Bytes.make 8 '\000' in
    let mac = Bytes.make 6 '\000' in
    let mtu = Bytes.make 8 '\000' in
    match miou_solo5_net_acquire name handle mac mtu with
    | 0 ->
        let mac = Bytes.unsafe_to_string mac in
        let handle = Int64.to_int (Bytes.get_int64_ne handle 0) in
        let mtu = Int64.to_int (Bytes.get_int64_ne mtu 0) in
        Ok (handle, { mac; mtu })
    | _ -> error_msgf "Impossible to connect the net-device %s" name

  let read t ~off ~len bstr =
    let rec go read_size =
      let result = miou_solo5_net_read t bstr off len read_size in
      match result with
      | 0 -> Int64.to_int (unsafe_get_int64_ne read_size 0)
      | 1 -> blocking_read t; go read_size
      | 2 -> invalid_arg "Mkernel.Net.read"
      | _ -> assert false (* UNSPEC *)
    in
    go (Bytes.make 8 '\000')

  let read_bigstring t ?(off = 0) ?len bstr =
    let len =
      match len with Some len -> len | None -> Bigarray.Array1.dim bstr - off
    in
    if len < 0 || off < 0 || off > Bigarray.Array1.dim bstr - len then
      invalid_arg "Mkernel.Net.read_bigstring: out of bounds";
    read t ~off ~len bstr

  let read_bytes =
    (* NOTE(dinosaure): Using [bstr] as a global is safe for 2 reasons. We
       don't have several domains with Solo5, so there can't be a data-race on
       this value. Secondly, we ensure that as soon as Solo5 writes to it, we
       save the bytes in the buffer given by the user without giving the
       scheduler a chance to execute another task (such as another
       [read_bytes]). *)
    let bstr = Bigarray.(Array1.create char c_layout 0x7ff) in
    fun t ?(off = 0) ?len buf ->
      let read_size = Bytes.make 8 '\000' in
      let rec go dst_off dst_len =
        if dst_len > 0 then begin
          let len = Int.min (Bigarray.Array1.dim bstr) dst_len in
          let result = miou_solo5_net_read t bstr off len read_size in
          match result with
          | 0 ->
              let len = Int64.to_int (unsafe_get_int64_ne read_size 0) in
              bigstring_blit_to_bytes bstr ~src_off:0 buf ~dst_off ~len;
              if len > 0 then go (dst_off + len) (dst_len - len)
              else dst_off - off
          | 1 -> blocking_read t; go dst_off dst_len
          | 2 -> invalid_arg "Mkernel.Net.read"
          | _ -> assert false (* UNSPEC *)
        end
        else dst_off - off
      in
      let len =
        match len with Some len -> len | None -> Bytes.length buf - off
      in
      if len < 0 || off < 0 || off > Bytes.length buf - len then
        invalid_arg "Mkernel.Net.read_bytes: out of bounds";
      go off len

  let rec write t ~off ~len bstr =
    match miou_solo5_net_write t off len bstr with
    | 0 -> ()
    | 1 -> write t ~off ~len bstr
    | 2 -> invalid_arg "Mkernel.Net.write"
    | _ -> assert false
  (* UNSPEC *)
  (* NOTE(dinosaure): we recall [write] when we receive [1]/[SOLO5_R_AGAIN]
     because on top of [Mkernel.Net.write], we assume that this function has
     effectively written the Ethernet frame we wanted.

     This is particularly important for protocols that want to write a frame to
     close an active connection and free up the associated resources. In a way,
     this operation must be "atomic" (in the sense that it must be indivisible
     by the scheduler) and effective (in the sense that its completion ensures
     that the frame has been written).

     [SOLO5_R_AGAIN] only appears for virtio. *)

  let write_bigstring t ?(off = 0) ?len bstr =
    let len =
      match len with Some len -> len | None -> Bigarray.Array1.dim bstr - off
    in
    if len < 0 || off < 0 || off > Bigarray.Array1.dim bstr - len then
      invalid_arg "Mkernel.Net.write_bigstring: out of bounds";
    write t ~off ~len bstr

  let write_into t ~len ~fn =
    let bstr = Bigarray.Array1.create Bigarray.char Bigarray.c_layout len in
    let len = fn bstr in
    write_bigstring t ~len bstr

  let write_string =
    let bstr = Bigarray.(Array1.create char c_layout 0x7ff) in
    fun t ?(off = 0) ?len str ->
      let rec go src_off src_len =
        if src_len > 0 then begin
          let len = Int.min (Bigarray.Array1.dim bstr) src_len in
          bigstring_blit_from_string str ~src_off bstr ~dst_off:0 ~len;
          write_bigstring t ~off:0 ~len bstr;
          Miou.yield ();
          go (src_off + len) (src_len - len)
        end
      in
      let len =
        match len with Some len -> len | None -> String.length str - off
      in
      if len < 0 || off < 0 || off > String.length str - len then
        invalid_arg "Mkernel.Net.write_string: out of bounds";
      go off len
end

module Block = struct
  include Block_direct

  let read t ~src_off ?(dst_off = 0) bstr =
    if dst_off < 0 || dst_off > Bigarray.Array1.dim bstr - t.pagesize then
      invalid_argf "TODO";
    if src_off land (t.pagesize - 1) != 0 then
      invalid_argf
        "Mkernel.Block.read: [off] must be aligned to the pagesize (%d)"
        t.pagesize;
    let syscall = Miou.syscall () in
    let args = { t; bstr; src_off; dst_off; syscall; cancelled= false } in
    let fn () = Queue.push (Rd args) domain.blocks in
    Miou.suspend ~fn syscall

  let write t ?(src_off = 0) ~dst_off bstr =
    if src_off < 0 || src_off > Bigarray.Array1.dim bstr - t.pagesize then
      invalid_arg "TODO";
    if dst_off land (t.pagesize - 1) != 0 then
      invalid_argf
        "Mkernel.Block.write: [off] must be aligned to the pagesize (%d)"
        t.pagesize;
    let syscall = Miou.syscall () in
    let args = { t; bstr; src_off; dst_off; syscall; cancelled= false } in
    let fn () = Queue.push (Wr args) domain.blocks in
    Miou.suspend ~fn syscall
end

module Hook = struct
  type t = (unit -> unit) Miou.Sequence.node

  let hooks = Miou.Sequence.create ()
  let add fn = Miou.Sequence.(add Left) hooks fn
  let remove node = Miou.Sequence.remove node
  let run () = Miou.Sequence.iter ~f:(fun fn -> fn ()) hooks
end

external clock_monotonic : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_monotonic"
[@@noalloc]

external clock_wall : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_wall"
[@@noalloc]

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

let collect_handles ~handles domain signals =
  let fn acc (handle, syscalls) =
    if (1 lsl handle) land handles != 0 then
      let signals = List.rev_map Miou.signal syscalls in
      (List.rev_append signals acc, (handle, []))
    else (acc, (handle, syscalls))
  in
  Handles.fold_left_map fn signals domain.handles

let rec consume_block domain signals =
  match Queue.pop domain.blocks with
  | Rd { cancelled= true; _ } | Wr { cancelled= true; _ } ->
      consume_block domain signals
  | Rd { t; bstr; src_off; dst_off; syscall; _ } ->
      Block.unsafe_read t ~src_off ~dst_off bstr;
      Miou.signal syscall :: signals
  | Wr { t; bstr; src_off; dst_off; syscall; _ } ->
      Block.unsafe_write t ~src_off ~dst_off bstr;
      Miou.signal syscall :: signals
  | exception Queue.Empty -> signals

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
  let fn2 = function
    | Rd ({ syscall; _ } as elt) | Wr ({ syscall; _ } as elt) ->
        if to_delete syscall then elt.cancelled <- true
  in
  Handles.filter_map fn0 domain.handles;
  Heapq.iter fn1 domain.sleepers;
  Queue.iter fn2 domain.blocks

external miou_solo5_yield : (int[@untagged]) -> (int[@untagged])
  = "unimplemented" "miou_solo5_yield"
[@@noalloc]

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

let select ~block cancelled_syscalls =
  clean domain cancelled_syscalls;
  let handles = ref 0 in
  let rec go signals =
    match wait_for ~block with
    | Infinity ->
        (* Miou tells us we can wait forever ([block = true]) and we have no
           sleepers. So we're going to: take action on the block devices and ask
           Solo5 if we need to manage an event. If we have an event after the
           action on the block device ([handles != 0]), we stop and send the
           signals to Miou. If not, we take the opportunity to possibly go
           further. *)
        let deadline = if Queue.is_empty domain.blocks then max_int else 0 in
        let signals = consume_block domain signals in
        handles := miou_solo5_yield deadline;
        Hook.run ();
        if !handles == 0 then go signals else signals
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
        let until = if Queue.is_empty domain.blocks then until else 0 in
        let t0 = !now () in
        let signals = consume_block domain signals in
        let t1 = !now () in
        let deadline = t1 + (until - (t1 - t0)) in
        handles := miou_solo5_yield deadline;
        Hook.run ();
        if !handles == 0 then (go [@tailcall]) signals else signals
  in
  let signals = consume_block domain [] in
  let signals = go signals in
  let signals = collect_handles ~handles:!handles domain signals in
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

let trim () =
  Gc.compact ();
  let trimmed = miou_solo5_malloc_trim () in
  Log.debug (fun m -> m "dlmalloc trimmed: %b" trimmed)

let run ?now:clock ?g devices fn =
  Option.iter (fun fn -> now := fn) clock;
  let alarm = Gc.create_alarm trim in
  let finally () = Gc.delete_alarm alarm in
  Fun.protect ~finally @@ fun () ->
  Miou.run ~events ~domains:0 ?g @@ fun () ->
  let run fn = fn () in
  go run devices fn
