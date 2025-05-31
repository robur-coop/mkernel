type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

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

let to_json = function
  | `Block name ->
      `O [ ("name", `String name); ("type", `String "BLOCK_BASIC") ]
  | `Net name -> `O [ ("name", `String name); ("type", `String "NET_BASIC") ]

module Net = struct
  type t = int
  type mac = string
  type cfg = { mac: mac; mtu: int }

  let connect _name = assert false
  let read_bigstring _t ?off:_ ?len:_ _bstr = assert false
  let read_bytes _t ?off:_ ?len:_ _buf = assert false
  let write_bigstring _t ?off:_ ?len:_ _bstr = assert false
  let write_string _t ?off:_ ?len:_ _str = assert false
end

module Block = struct
  type t = { handle: int; pagesize: int }

  let pagesize _ = assert false
  let connect _name = assert false
  let atomic_read _t ~src_off:_ ?dst_off:_ _bstr = assert false
  let atomic_write _t ?src_off:_ ~dst_off:_ _bstr = assert false
  let read _t ~src_off:_ ?dst_off:_ _bstr = assert false
  let write _t ~src_off:_ ?dst_off:_ _bstr = assert false
end

module Hook = struct
  type t = (unit -> unit) Miou.Sequence.node

  let hooks = Miou.Sequence.create ()
  let add fn = Miou.Sequence.(add Left) hooks fn
  let remove node = Miou.Sequence.remove node
end

external clock_monotonic : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_monotonic"
[@@noalloc]

external clock_wall : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_wall"
[@@noalloc]

let sleep _ = assert false

type 'a arg =
  | Args : ('k, 'res) devices -> 'a arg
  | Block : string -> Block.t arg
  | Net : string -> (Net.t * Net.cfg) arg

and ('k, 'res) devices =
  | [] : (unit -> 'res, 'res) devices
  | ( :: ) : 'a arg * ('k, 'res) devices -> ('a -> 'k, 'res) devices

let net name = Net name
let block name = Block name
let map _fn args = Args args
let const _ = Args []

type t = [ `Block of string | `Net of string ]

let collect devices =
  let rec go : type k res. t list -> (k, res) devices -> t list =
   fun acc -> function
     | [] -> List.rev acc
     | Block name :: rest -> go (`Block name :: acc) rest
     | Net name :: rest -> go (`Net name :: acc) rest
     | Args vs :: rest -> go (go acc vs) rest
  in
  go [] devices

let run ?g:_ args _fn =
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
