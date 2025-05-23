let cachet_of_block ~cachesize blk () =
  let map blk ~pos len =
    let bstr = Bigarray.(Array1.create char c_layout len) in
    Miou_solo5.Block.read blk ~src_off:pos bstr;
    bstr
  in
  let pagesize = Miou_solo5.Block.pagesize blk in
  Cachet.make ~cachesize ~pagesize ~map blk

let cachet ~cachesize name =
  let open Miou_solo5 in
  map (cachet_of_block ~cachesize) [ block name ]

let run cachesize =
  Miou_solo5.(run [ cachet ~cachesize "simple" ]) @@ fun blk () ->
  let pagesize = Cachet.pagesize blk in
  let prm =
    Miou.async @@ fun () ->
    let bstr = Bigarray.(Array1.create char c_layout (2 * pagesize)) in
    let blk = Cachet.fd blk in
    Miou_solo5.Block.atomic_read blk ~src_off:0 ~dst_off:pagesize bstr;
    let bstr = Cachet.Bstr.of_bigstring bstr in
    let str = Cachet.Bstr.sub_string ~off:pagesize ~len:pagesize bstr in
    let hash = Digest.string str in
    Fmt.pr "%08x: %s\n%!" 0 (Digest.to_hex hash)
  in
  let str = Cachet.get_string blk pagesize ~len:pagesize in
  let hash = Digest.string str in
  Fmt.pr "%08x: %s\n%!" pagesize (Digest.to_hex hash);
  Miou.await_exn prm

open Cmdliner

let cachesize =
  let doc = "The size of the cache (must be a power of two)." in
  let open Arg in
  value & opt int 0x100 & info [ "cachesize" ] ~doc ~docv:"NUMBER"

let term =
  let open Term in
  const run $ cachesize

let cmd =
  let doc = "A simple unikernel to read a block device." in
  let man = [] in
  let info = Cmd.info "blk" ~doc ~man in
  Cmd.v info term

let () = Cmd.(exit @@ eval cmd)
