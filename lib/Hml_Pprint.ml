(** This modules exports a modified version of {!Pprint} with extra printers. *)

include Pprint

(* This module contains extra helper functions for [Pprint]. *)

let arrow = string "->"

let ccolon = colon ^^ colon

let int i = string (string_of_int i)

let utf8_length s =
  (* Stolen from Batteries *)
  let rec length_aux s c i =
    if i >= String.length s then c else
    let n = Char.code (String.unsafe_get s i) in
    let k =
      if n < 0x80 then 1 else
      if n < 0xe0 then 2 else
      if n < 0xf0 then 3 else 4
    in
    length_aux s (c + 1) (i + k)
  in
  length_aux s 0 0

let print_string s =
  fancystring s (utf8_length s)

let name_gen count =
  (* Of course, won't work nice if more than 26 type parameters... *)
  let alpha = "α" in
  let c0 = Char.code alpha.[1] in
  Hml_List.make count (fun i ->
    let code = c0 + i in
    Printf.sprintf "%c%c" alpha.[0] (Char.chr code)
  )

(* [heading head body] prints [head]; breaks a line and indents by 2,
 if necessary; then prints [body]. *)
let heading head body =
  group (
    nest 2 (
      group head ^^ linebreak ^^
      body
    )
  )

(* [jump body] either displays a space, followed with [body], followed
   with a space, all on a single line; or breaks a line, prints [body]
   at indentation 2. *)
let jump body =
  group (nest 2 (line ^^ body))

(* [definition head body cont] prints [head]; prints [body], surrounded
   with spaces and, if necessary, indented by 2; prints the keyword [in];
   breaks a line, if necessary; and prints [cont]. *)
let definition head body cont =
  group (
    group head ^^ jump body ^^ text "in"
  ) ^^ line ^^
  cont

(* [join sep (s1 :: s2 :: ... :: sn)] returns
 * [s1 ^^ sep ^^ s2 ^^ ... ^^ sep ^^ sn] *)
let join sep strings =
  match strings with
  | hd :: tl ->
      List.fold_left (fun sofar s -> sofar ^^ sep ^^ s) hd tl
  | [] ->
      empty

(* [join_left sep (s1 :: s2 :: ... :: sn)] returns
 * [sep ^^ s1 ^^ sep ^^ s2 ^^ ... ^^ sep ^^ sn] *)
let join_left sep strings =
  List.fold_left (fun sofar s -> sofar ^^ sep ^^ s) empty strings
