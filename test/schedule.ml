let () =
  Miou_solo5.run [] @@ fun () ->
  let prm = Miou.async @@ fun () -> print_endline "World" in
  print_endline "Hello"; Miou.await_exn prm
