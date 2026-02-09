type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

let device =
  let open Jsont in
  let open Object in
  let with_name = map Fun.id |> mem "name" ~enc:Fun.id string |> finish in
  let block = Case.map "BLOCK_BASIC" with_name ~dec:(fun name -> `Block name) in
  let net = Case.map "NET_BASIC" with_name ~dec:(fun name -> `Net name) in
  let enc_case = function
    | `Block name -> Case.value block name
    | `Net name -> Case.value net name
  in
  let cases = Case.[ make block; make net ] in
  map Fun.id |> case_mem "type" string ~enc:Fun.id ~enc_case cases |> finish

let t =
  let open Jsont in
  Object.map (fun _ _ devices -> devices)
  |> Object.mem "type" ~enc:(Fun.const "solo5.manifest") string
  |> Object.mem "version" ~enc:(Fun.const 1) int
  |> Object.mem "devices" ~enc:Fun.id (list device)
  |> Object.finish

module Net = struct
  type t = int
  type mac = string
  type cfg = { mac: mac; mtu: int }

  let connect _name = assert false
  let read_bigstring _t ?off:_ ?len:_ _bstr = assert false
  let read_bytes _t ?off:_ ?len:_ _buf = assert false
  let write_bigstring _t ?off:_ ?len:_ _bstr = assert false
  let write_string _t ?off:_ ?len:_ _str = assert false
  let write_into _t ~len:_ ~fn:_ = assert false
end

module Block = struct
  type t = { handle: int; pagesize: int }

  let pagesize _ = assert false
  let length _ = assert false
  let connect _name = assert false
  let atomic_read _t ~src_off:_ ?dst_off:_ _bstr = assert false
  let atomic_write _t ?src_off:_ ~dst_off:_ _bstr = assert false
  let read _t ~src_off:_ ?dst_off:_ _bstr = assert false
  let write _t ?src_off:_ ~dst_off:_ _bstr = assert false
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

let run ?now:_ ?g:_ args _fn =
  let devices = collect args in
  match Jsont_bytesrw.encode_string t devices with
  | Ok str -> print_endline str; exit 0
  | Error str -> prerr_endline str; exit 1
