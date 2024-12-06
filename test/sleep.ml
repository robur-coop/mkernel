let _1s = 1_000_000_000

let () = Miou_solo5.run [] @@ fun () ->
  Miou_solo5.sleep _1s;
  print_endline "Hello";
  Miou_solo5.sleep _1s;
  print_endline "World"
