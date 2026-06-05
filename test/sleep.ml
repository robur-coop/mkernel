let _1s = 1_000_000_000
let nsec_per_day = Int64.mul 86_400L 1_000_000_000L
let ps_per_ns = 1_000L

let now () =
  let nsec = Mkernel.clock_wall () in
  let nsec = Int64.of_int nsec in
  let days = Int64.div nsec nsec_per_day in
  let rem_ns = Int64.rem nsec nsec_per_day in
  let rem_ps = Int64.mul rem_ns ps_per_ns in
  Ptime.v (Int64.to_int days, rem_ps)

let () =
  Mkernel.run [] @@ fun () ->
  Mkernel.sleep _1s;
  print_endline "Hello";
  let t0 = now () in
  let at = Option.get (Ptime.add_span t0 (Ptime.Span.of_int_s 1)) in
  Mkernel.wakeup ~at;
  let t1 = now () in
  assert (Ptime.(Span.to_int_s (diff t1 t0)) = Some 1);
  print_endline "World"
