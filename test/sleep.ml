let _1s = 1_000_000_000

let () =
  Mkernel.run [] @@ fun () ->
  Mkernel.sleep _1s;
  print_endline "Hello";
  Mkernel.sleep _1s;
  print_endline "World"
