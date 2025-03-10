type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

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
