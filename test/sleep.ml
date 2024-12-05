let _1s = 1_000_000_000

let sleep_and ns fn =
  Miou_solo5.sleep ns;
  fn ()

let rec repeat_until n fn =
  if n > 0 then begin
    fn ();
    repeat_until (n - 1) fn
  end

let () = Miou_solo5.run @@ fun () ->
  let prm0 = Miou.async @@ fun () ->
    repeat_until 3 @@ fun () ->
    sleep_and _1s @@ fun () ->
    print_endline "Hello" in
  let prm1 = Miou.async @@ fun () ->
    repeat_until 3 @@ fun () ->
    sleep_and _1s @@ fun () ->
    print_endline "World" in
  let res = Miou.await_all [ prm0; prm1 ] in
  List.iter (function Ok () -> () | Error exn -> raise exn) res
