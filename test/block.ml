external unsafe_get_char : Miou_solo5.bigstring -> int -> char
  = "%caml_ba_ref_1"

let bigstring_to_string v =
  let len = Bigarray.Array1.dim v in
  let res = Bytes.create len in
  for i = 0 to len - 1 do
    Bytes.set res i (unsafe_get_char v i)
  done;
  Bytes.unsafe_to_string res

let () =
  Miou_solo5.(run [ block "simple" ]) @@ fun blk () ->
  let pagesize = Miou_solo5.Block.pagesize blk in
  let bstr = Bigarray.(Array1.create char c_layout pagesize) in
  let prm =
    Miou.async @@ fun () ->
    Miou_solo5.Block.atomic_read blk ~off:0 bstr;
    let str = bigstring_to_string bstr in
    let hash = Digest.string str in
    Fmt.pr "%08x: %s\n%!" 0 (Digest.to_hex hash)
  in
  Miou_solo5.Block.read blk ~off:pagesize bstr;
  let str = bigstring_to_string bstr in
  let hash = Digest.string str in
  Fmt.pr "%08x: %s\n%!" pagesize (Digest.to_hex hash);
  Miou.await_exn prm
