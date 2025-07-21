let run foo bar =
  Mkernel.(run []) @@ fun () ->
  let argv = Array.to_list Sys.argv in
  Fmt.pr "%s\n%!" (String.concat " " argv);
  Fmt.pr "foo: %a\n%!" Fmt.(Dump.option (fmt "%S")) foo;
  Fmt.pr "bar: %a\n%!" Fmt.(Dump.option (fmt "%S")) bar

open Cmdliner

let foo =
  let doc = "Foo" in
  let open Arg in
  value & opt (some string) None & info [ "foo" ] ~doc

let bar =
  let doc = "Bar" in
  let open Arg in
  value & opt (some string) None & info [ "bar" ] ~doc

let term =
  let open Term in
  const run $ foo $ bar

let cmd =
  let doc = "A simple unikernel to test the command-line." in
  let man = [] in
  let info = Cmd.info "cmd" ~doc ~man in
  Cmd.v info term

let () = Cmd.(exit @@ eval cmd)
