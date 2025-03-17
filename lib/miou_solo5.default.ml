let src = Logs.Src.create "miou.solo5"

module Log = (val Logs.src_log src : Logs.LOG)

exception Solo5_error of int * string * string

let _ =
  Callback.register_exception "Solo5.Solo5_error" (Solo5_error (0, "", ""))

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

[@@@warning "-32-34-37"]

let error_msgf fmt = Fmt.kstr (fun msg -> Error (`Msg msg)) fmt
let failwithf fmt = Fmt.kstr failwith fmt
let failwith_error = function Ok () -> () | Error msg -> Fmt.failwith "%s" msg

module Json = struct
  type value = [ `Null | `Bool of bool | `String of string | `Float of float ]
  type t = [ value | `A of t list | `O of (string * t) list ]

  module Stack = struct
    type stack =
      | In_array of t list * stack
      | In_object of (string * t) list * stack
      | Empty
  end

  let encode ?minify ?(size_chunk = 0x800) ~output t =
    let encoder = Jsonm.encoder ?minify `Manual in
    let buf = Bytes.create size_chunk in
    let rec encode k stack value =
      match Jsonm.encode encoder value with
      | `Ok -> k stack
      | `Partial ->
          let len = Bytes.length buf - Jsonm.Manual.dst_rem encoder in
          output (Bytes.sub_string buf 0 len);
          Jsonm.Manual.dst encoder buf 0 (Bytes.length buf);
          encode k stack `Await
    and value k v stack =
      match v with
      | #value as v -> encode (continue k) stack (`Lexeme v)
      | `O ms -> encode (obj k ms) stack (`Lexeme `Os)
      | `A vs -> encode (arr k vs) stack (`Lexeme `As)
    and obj k ms stack =
      match ms with
      | (n, v) :: ms ->
          let stack = Stack.In_object (ms, stack) in
          encode (value k v) stack (`Lexeme (`Name n))
      | [] -> encode (continue k) stack (`Lexeme `Oe)
    and arr k vs stack =
      match vs with
      | v :: vs ->
          let stack = Stack.In_array (vs, stack) in
          value k v stack
      | [] -> encode (continue k) stack (`Lexeme `Ae)
    and continue k = function
      | Stack.In_array (vs, stack) -> arr k vs stack
      | Stack.In_object (ms, stack) -> obj k ms stack
      | Stack.Empty as stack -> encode k stack `End
    in
    Jsonm.Manual.dst encoder buf 0 (Bytes.length buf);
    value (Fun.const ()) t Stack.Empty
end

type device = { name: string; value: value }
and value = Net of net | Block of block
and net = { interface: string; mac: Macaddr.t option }
and block = { filename: string; sector_size: int }
and profiling = { version: int; devices: device list }

let json =
  let open Jsont in
  let macaddr =
    let dec str =
      Result.map_error (fun (`Msg msg) -> msg) (Macaddr.of_string str)
    in
    Jsont.of_of_string dec ~enc:Macaddr.to_string
  in
  let net =
    Object.map ~kind:"NET_BASIC" (fun name interface mac ->
        (name, { interface; mac }))
    |> Object.mem "name" Jsont.string ~enc:(fun (name, _) -> name)
    |> Object.mem "interface" Jsont.string ~enc:(fun (_, t) -> t.interface)
    |> Object.opt_mem "mac" macaddr ~enc:(fun (_, t) -> t.mac)
    |> Object.finish
  in
  let block =
    Object.map ~kind:"BLOCK_BASIC" (fun name filename sector_size ->
        (name, { filename; sector_size }))
    |> Object.mem "name" Jsont.string ~enc:(fun (name, _) -> name)
    |> Object.mem "filename" Jsont.string ~enc:(fun (_, t) -> t.filename)
    |> Object.mem "sector-size" Jsont.int ~dec_absent:512 ~enc:(fun (_, t) ->
           t.sector_size)
    |> Object.finish
  in
  let cases, enc_case =
    let net =
      Object.Case.map "NET_BASIC" net ~dec:(fun (name, net) ->
          { name; value= Net net })
    in
    let block =
      Object.Case.map "BLOCK_BASIC" block ~dec:(fun (name, block) ->
          { name; value= Block block })
    in
    let enc_case = function
      | { name; value= Net v } -> Object.Case.value net (name, v)
      | { name; value= Block v } -> Object.Case.value block (name, v)
    in
    (Object.Case.[ make net; make block ], enc_case)
  in
  let device =
    Object.map ~kind:"miou.solo5.device" Fun.id
    |> Object.case_mem "type" Jsont.string ~enc:Fun.id ~enc_case cases
    |> Object.finish
  in
  let fn version _type devices = { version; devices } in
  Object.map ~kind:"miou.solo5.profiling" fn
  |> Object.mem "version" Jsont.int ~enc:(Fun.const 1)
  |> Object.mem "type" Jsont.string ~enc:(Fun.const "miou.solo5.profiling")
  |> Object.mem "devices" (Jsont.list device) ~enc:(fun t -> t.devices)
  |> Object.finish

let existing_file filename =
  Sys.file_exists filename && Sys.is_directory filename = false

let setup_profiling = ref None

let load_devices filename =
  let ic = open_in filename in
  let finally () = close_in ic in
  Fun.protect ~finally @@ fun () ->
  let len = in_channel_length ic in
  let buf = Bytes.create len in
  really_input ic buf 0 len;
  let str = Bytes.unsafe_to_string buf in
  let ( let* ) = Result.bind in
  let* profiling = Jsont_bytesrw.decode_string json str in
  Ok (setup_profiling := Some profiling)

let find_net_device name =
  match !setup_profiling with
  | None -> failwithf "Not devices specified"
  | Some { devices; _ } -> (
      let fn = function
        | { name= name'; value= Net _ } -> String.equal name name'
        | _ -> false
      in
      match List.find_opt fn devices with
      | Some { value= Net { interface; _ }; _ } -> interface
      | _ -> failwithf "Net device %s not found" name)

let () =
  match Sys.getenv_opt "MIOU_PROFILING" with
  | Some filename when existing_file filename ->
      failwith_error (load_devices filename)
  | _ -> ()

let to_json = function
  | `Block name ->
      `O [ ("name", `String name); ("type", `String "BLOCK_BASIC") ]
  | `Net name -> `O [ ("name", `String name); ("type", `String "NET_BASIC") ]

external miou_solo5_net_connect : string -> (int[@untagged])
  = "unimplemented" "miou_solo5_net_connect"
[@@noalloc]

external unsafe_get_int64_ne : bytes -> int -> int64 = "%caml_bytes_get64u"

external miou_solo5_net_read :
     (int[@untagged])
  -> bigstring
  -> (int[@untagged])
  -> (int[@untagged])
  -> bytes
  -> int = "unimplemented" "miou_solo5_net_read"
[@@noalloc]

external miou_solo5_net_write :
  (int[@untagged]) -> (int[@untagged]) -> (int[@untagged]) -> bigstring -> unit
  = "unimplemented" "miou_solo5_net_write"
[@@noalloc]

external miou_solo5_select : int list -> float -> int list
  = "unimplemented" "miou_solo5_select"

module File_descrs = struct
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

  let iter fn t = List.iter (fun (k, v) -> fn k v) t.contents
end

type elt = { time: int; syscall: Miou.syscall; mutable cancelled: bool }

module Heapq = Miou.Pqueue.Make (struct
  type t = elt

  let dummy = { time= 0; syscall= Obj.magic (); cancelled= false }
  let compare { time= a; _ } { time= b; _ } = Int.compare a b
end)

type domain = { fds: Miou.syscall list File_descrs.t; sleepers: Heapq.t }

let domain = { fds= File_descrs.create 0x100; sleepers= Heapq.create () }

let blocking_read fd =
  let syscall = Miou.syscall () in
  let fn () = File_descrs.append domain.fds fd syscall in
  Miou.suspend ~fn syscall

module Net = struct
  type t = int
  type mac = string
  type cfg = { mac: mac; mtu: int }

  let connect name =
    Log.debug (fun m -> m "search %s device" name);
    let name = find_net_device name in
    Log.debug (fun m -> m "attach tap interface %s" name);
    match miou_solo5_net_connect name with
    | -1 -> error_msgf "Interface %s not found" name
    | -2 -> error_msgf "Interface %s is not up" name
    | -3 -> error_msgf "Impossible to open %s" name
    | -4 -> error_msgf "Impossible to attach %s" name
    | -5 -> error_msgf "Invalid attached TAP interface"
    | fd ->
        let v = Random.int64 Int64.max_int in
        let buf = Bytes.create 8 in
        Bytes.set_int64_be buf 0 v;
        Bytes.set_uint8 buf 0 (Bytes.get_uint8 buf 0 land 0xfe);
        Bytes.set_uint8 buf 0 (Bytes.get_uint8 buf 0 lor 0x02);
        let mac = Bytes.sub_string buf 0 6 in
        let cfg = { mac; mtu= 1500 } in
        Ok (fd, cfg)

  let read t ~off ~len bstr =
    let rec go read_size =
      blocking_read t;
      let result = miou_solo5_net_read t bstr off len read_size in
      match result with
      | 0 -> Int64.to_int (unsafe_get_int64_ne read_size 0)
      | 1 -> blocking_read t; go read_size
      | 2 -> invalid_arg "Miou_solo5.Net.read"
      | _ -> assert false (* UNSPEC *)
    in
    go (Bytes.make 8 '\000')

  let read_bigstring t ?(off = 0) ?len bstr =
    let len =
      match len with Some len -> len | None -> Bigarray.Array1.dim bstr - off
    in
    if len < 0 || off < 0 || off > Bigarray.Array1.dim bstr - len then
      invalid_arg "Miou_solo5.Net.read_bigstring: out of bounds";
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
          | 2 -> invalid_arg "Miou_solo5.Net.read"
          | _ -> assert false (* UNSPEC *)
        end
        else dst_off - off
      in
      let len =
        match len with Some len -> len | None -> Bytes.length buf - off
      in
      if len < 0 || off < 0 || off > Bytes.length buf - len then
        invalid_arg "Miou_solo5.Net.read_bytes: out of bounds";
      go off len

  let write t ~off ~len bstr = miou_solo5_net_write t off len bstr

  let write_bigstring t ?(off = 0) ?len bstr =
    let len =
      match len with Some len -> len | None -> Bigarray.Array1.dim bstr - off
    in
    if len < 0 || off < 0 || off > Bigarray.Array1.dim bstr - len then
      invalid_arg "Miou_solo5.Net.write_bigstring: out of bounds";
    write t ~off ~len bstr

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
        invalid_arg "Miou_solo5.Net.write_string: out of bounds";
      go off len
end

module Block = struct
  type t = { handle: int; pagesize: int }

  let pagesize _ = assert false
  let connect _name = assert false
  let atomic_read _t ~off:_ _bstr = assert false
  let atomic_write _t ~off:_ _bstr = assert false
  let read _t ~off:_ _bstr = assert false
  let write _t ~off:_ _bstr = assert false
end

external clock_monotonic : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_monotonic"
[@@noalloc]

external clock_wall : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_wall"
[@@noalloc]

let sleep until =
  let syscall = Miou.syscall () in
  let elt = { time= clock_monotonic () + until; syscall; cancelled= false } in
  Heapq.insert elt domain.sleepers;
  Miou.suspend syscall

let rec sleeper domain =
  match Heapq.find_min_exn domain.sleepers with
  | exception Heapq.Empty -> None
  | { cancelled= true; _ } ->
      Heapq.delete_min_exn domain.sleepers;
      sleeper domain
  | { time; _ } -> Some time

let in_the_past t = t == 0 || t <= clock_monotonic ()

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

let collect_file_descrs file_descrs domain signals =
  let fn acc (file_descr, syscalls) =
    if List.exists (Int.equal file_descr) file_descrs then
      let signals = List.rev_map Miou.signal syscalls in
      (List.rev_append signals acc, (file_descr, []))
    else (acc, (file_descr, syscalls))
  in
  File_descrs.fold_left_map fn signals domain.fds

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
  File_descrs.filter_map fn0 domain.fds;
  Heapq.iter fn1 domain.sleepers

let file_descrs tbl =
  let res = ref [] in
  File_descrs.iter (fun k _ -> res := k :: !res) tbl;
  !res

let select ~block cancelled_syscalls =
  clean domain cancelled_syscalls;
  let timeout =
    match (sleeper domain, block) with
    | None, true -> -1.0
    | (None | Some _), false -> 0.0
    | Some value, true ->
        let value = value - clock_monotonic () in
        let value = Int.max value 0 in
        Float.of_int value /. 1e-9
  in
  let rds = file_descrs domain.fds in
  match miou_solo5_select rds timeout with
  | [] -> collect_sleepers domain []
  | rds ->
      let signals = collect_sleepers domain [] in
      collect_file_descrs rds domain signals

let events _domain = { Miou.interrupt= ignore; select; finaliser= ignore }

type 'a arg =
  | Args : ('k, 'res) devices * 'k -> 'res arg
  | Block : string -> Block.t arg
  | Net : string -> (Net.t * Net.cfg) arg
  | Const : 'a -> 'a arg

and ('k, 'res) devices =
  | [] : (unit -> 'res, 'res) devices
  | ( :: ) : 'a arg * ('k, 'res) devices -> ('a -> 'k, 'res) devices

let net name = Net name
let block name = Block name
let map fn args = Args (args, fn)
let const v = Const v

type t = [ `Block of string | `Net of string ]

let collect devices =
  let rec go : type k res. t list -> (k, res) devices -> t list =
   fun acc -> function
     | [] -> List.rev acc
     | Block name :: rest -> go (`Block name :: acc) rest
     | Net name :: rest -> go (`Net name :: acc) rest
     | Args (vs, _) :: rest -> go (go acc vs) rest
     | Const _ :: rest -> go acc rest
  in
  go [] devices

let rec ctor : type a. a arg -> a = function
  | Args (args, fn) -> go (fun fn -> fn ()) args fn
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

and go : type k res. ((unit -> res) -> res) -> (k, res) devices -> k -> res =
 fun run -> function
  | [] -> fun fn -> run fn
  | arg :: devices ->
      let v = ctor arg in
      fun fn ->
        let r = fn v in
        go run devices r

let run ?g args fn =
  match !setup_profiling with
  | Some _profiling ->
      Miou.run ~events ~domains:0 ?g @@ fun () ->
      let run fn = fn () in
      go run args fn
  | None ->
      let devices = collect args in
      let v =
        `O
          List.
            [
              ("type", `String "solo5.manifest"); ("version", `Float 1.0)
            ; ("devices", `A (List.map to_json devices))
            ]
      in
      let output str = output_string stdout str in
      Json.encode ~output v; exit 0
