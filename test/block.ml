let cachet_of_block ~cachesize blk () =
  let map blk ~pos len =
    let bstr = Bigarray.(Array1.create char c_layout len) in
    Mkernel.Block.read blk ~src_off:pos bstr;
    bstr
  in
  let pagesize = Mkernel.Block.sector_size blk in
  Cachet.make ~cachesize ~pagesize ~map blk

let cachet ~cachesize name =
  let open Mkernel in
  map (cachet_of_block ~cachesize) [ block name ]

let () =
  Mkernel.(run [ cachet ~cachesize:512 "0" ]) @@ fun blk () ->
  let sector_size = Cachet.pagesize blk in
  let prm =
    Miou.async @@ fun () ->
    let bstr = Bigarray.(Array1.create char c_layout (2 * sector_size)) in
    let blk = Cachet.fd blk in
    Mkernel.Block.atomic_read blk ~src_off:0 ~dst_off:sector_size bstr;
    let bstr = Cachet.Bstr.of_bigstring bstr in
    let str = Cachet.Bstr.sub_string ~off:sector_size ~len:sector_size bstr in
    let hash = Digest.string str in
    Fmt.pr "%08x: %s\n%!" 0 (Digest.to_hex hash)
  in
  Miou.await_exn prm;
  let str = Cachet.get_string blk sector_size ~len:sector_size in
  let hash = Digest.string str in
  Fmt.pr "%08x: %s\n%!" sector_size (Digest.to_hex hash)

(*
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
*)
