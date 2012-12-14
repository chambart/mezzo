(*****************************************************************************)
(*  Mezzo, a programming language based on permissions                       *)
(*  Copyright (C) 2011, 2012 Jonathan Protzenko and François Pottier         *)
(*                                                                           *)
(*  This program is free software: you can redistribute it and/or modify     *)
(*  it under the terms of the GNU General Public License as published by     *)
(*  the Free Software Foundation, either version 3 of the License, or        *)
(*  (at your option) any later version.                                      *)
(*                                                                           *)
(*  This program is distributed in the hope that it will be useful,          *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of           *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the            *)
(*  GNU General Public License for more details.                             *)
(*                                                                           *)
(*  You should have received a copy of the GNU General Public License        *)
(*  along with this program.  If not, see <http://www.gnu.org/licenses/>.    *)
(*                                                                           *)
(*****************************************************************************)

open Lexer

(* -------------------------------------------------------------------------- *)

(* Lexing and parsing, built on top of [grammar]. *)

let lex_and_parse file_path entry_point =
  let file_desc = open_in file_path in
  let lexbuf = Ulexing.from_utf8_channel file_desc in
  let the_parser = MenhirLib.Convert.Simplified.traditional2revised entry_point in
  try
    Lexer.init file_path;
    the_parser (fun _ -> Lexer.token lexbuf)
  with
    | Ulexing.Error ->
	Printf.eprintf
          "Lexing error at offset %i\n" (Ulexing.lexeme_end lexbuf);
        exit 255
    | Ulexing.InvalidCodepoint i ->
	Printf.eprintf
          "Invalid code point %i at offset %i\n" i (Ulexing.lexeme_end lexbuf);
        exit 254
    | Grammar.Error ->
        Hml_String.beprintf "%a\nError: Syntax error\n"
          print_position lexbuf;
        exit 253
    | Lexer.LexingError e ->
        Hml_String.beprintf "%a\n"
          Lexer.print_error (lexbuf, e);
        exit 252
;;

let mkprefix path =
  if !Options.no_auto_include && path = !Options.filename then
    []
  else
    let autoload_modules = [
      "core.mzi";
      "pervasives.mzi";
    ] in
    let me = Filename.basename path in
    let my_dir = Filename.dirname path in
    let chop l =
      let rec chop acc = function
        | hd :: tl ->
            if hd = me then
              List.rev acc
            else
              chop (hd :: acc) tl
        | [] ->
            List.rev acc
      in
      chop [] l
    in
    let corelib_dir =
      Filename.concat Configure.root_dir "corelib"
    in
    let me_in_core_directory =
      Utils.absolute_path corelib_dir = Utils.absolute_path my_dir
    in
    Log.debug "In core directory? %b" me_in_core_directory;
    let modules =
      if me_in_core_directory then
        chop autoload_modules
      else
        autoload_modules
    in
    List.map (fun x ->
      let name = Filename.chop_suffix x ".mzi" in
      SurfaceSyntax.OpenDirective (Module.register name)
    ) modules 
;;

let lex_and_parse_implementation path =
  mkprefix path @ lex_and_parse path Grammar.implementation
;;

let lex_and_parse_interface path =
  mkprefix path @ lex_and_parse path Grammar.interface
;;


(* -------------------------------------------------------------------------- *)

(* Filename handling, as well as include directories handling. *)

let include_dirs: string list ref =
  ref []
;;

let add_include_dir dir =
  include_dirs := dir :: !include_dirs
;;

let module_name_for_file_path (f: string): Module.name =
  let f = Filename.basename f in
  let f =
    if Filename.check_suffix f ".mz" then
      Filename.chop_suffix f ".mz"
    else if Filename.check_suffix f ".mzi" then
      Filename.chop_suffix f ".mzi"
    else
      Log.error "This is unexpected"
  in
  Module.register f
;;

let find_in_include_dirs (filename: string): string option =
  let module M = struct exception Found of string end in
  try
    List.iter (fun dir ->
      let open Filename in
      let dir =
        if is_relative dir then
          current_dir_name ^ dir_sep ^ dir
        else
          dir
      in
      let path = concat dir filename in
      if Sys.file_exists path then
        raise (M.Found path)
    ) !include_dirs;
    None
  with M.Found s ->
    Some s
;;

let iface_file_path_for_module_name (mname: Module.name): string option =
  let f = Module.print mname in
  let f = f ^ ".mzi" in
  find_in_include_dirs f
;;

let cache =
  Hashtbl.create 11
;;

let find_and_lex_interface (mname: Module.name): SurfaceSyntax.interface =
  try
    Hashtbl.find cache mname
  with Not_found ->
    let ifpath = iface_file_path_for_module_name mname in
    match ifpath with
    | Some ifpath ->
        let i = lex_and_parse_interface ifpath in
        Hashtbl.add cache mname i;
        i
    | None ->
        Log.error "No interface for module %a" Module.p mname
;;

(* [build_interface env mname] finds the right interface file for [mname], and
 * lexes it, parses it, and returns a desugared version of it, reading for
 * importing into some environment. *)
let build_interface (env: Types.env) (mname: Module.name): Types.env * Expressions.interface =
  let iface = find_and_lex_interface mname in
  let env = { env with Types.module_name = mname } in
  KindCheck.check_interface env iface;
  env, TransSurface.translate_interface env iface
;;


(* -------------------------------------------------------------------------- *)

(* Main routines. *)

(* Check a module against its interface. Not related to importing an interface
 * or anything. *)
let check_interface env signature exports =
  KindCheck.check_interface env signature;
  (* It may very well be that [Interfaces.check] subsumes what
   * [KindCheck.check_interface] does. *)
  Interfaces.check env signature exports
;;


let import_dependencies_in_scope env deps =
  List.fold_left (fun env mname ->
    Log.debug "Massive import, %a" Module.p mname;
    let env, iface = build_interface env mname in

    (* [env] has the right module name at this stage *)
    let env = Modules.import_interface env iface in
    Log.debug "Imported %a, now has names %a"
      Module.p mname
      Types.TypePrinter.pexports env;
    env
  ) env deps
;;


(* This performs the bulk of the work. *)
let check_implementation
    (mname: Module.name)
    (program: SurfaceSyntax.implementation)
    (interface: SurfaceSyntax.interface option) =

  let open Expressions in

  let env = Types.empty_env in

  (* Find all the dependencies... *)
  Log.debug ~level:2 "\n%s***%s Computing dependencies for %a"
    Bash.colors.Bash.yellow Bash.colors.Bash.default
    Module.p mname;
  let deps = Modules.all_dependencies mname (fun mname' ->
    if Module.equal mname mname' then
      program
    else
      find_and_lex_interface mname')
  in

  (* And import them all in scope. *)
  Log.debug ~level:2 "\n%s***%s Importing the dependencies of %a in scope"
    Bash.colors.Bash.yellow Bash.colors.Bash.default
    Module.p mname;
  let env = import_dependencies_in_scope env deps in

  let env = { env with Types.module_name = mname } in

  (* First pass of kind-checking; it checks for unbound variables and variables
   * with the wrong kind. *)
  KindCheck.check_implementation env program;

  (* We need to translate the program down to the internal syntax. *)
  let program = TransSurface.translate_implementation env program in

  (* [type_check] also returns a list of points, with the property that if x
   * comes later than y in the file, then the point associated to x will come
   * before that of y in the list of points. *)
  let type_check env program =
    let rec type_check env program pointss =
      match program with
      | DataTypeGroup group :: blocks ->
          Log.debug ~level:2 "\n%s***%s Processing data type group:\n%a"
            Bash.colors.Bash.yellow Bash.colors.Bash.default
            KindCheck.KindPrinter.pgroup (env, group);

          (* The binders in the data type group will be opened in the rest of the
           * blocks. Also performs the actual binding in the data type group, as
           * well as the variance and fact inference. *)
          let env, blocks, points = DataTypeGroup.bind_data_type_group env group blocks in
          (* Move on to the rest of the blocks. *)
          type_check env blocks (points :: pointss)
      | ValueDeclarations decls :: blocks ->
          Log.debug ~level:2 "\n%s***%s Processing declarations:\n%a"
            Bash.colors.Bash.yellow Bash.colors.Bash.default
            Expressions.ExprPrinter.pdeclarations (env, decls);

          (* Perform the actual checking. The binders in the declaration group
           * will be opened in [blocks] as well. *)
          let env, blocks, points = TypeChecker.check_declaration_group env decls blocks in
          (* Move on to the rest of the blocks. *)
          type_check env blocks (points :: pointss)
      | _ :: _ ->
          Log.error "The parser should forbid this"
      | [] ->
          (* Print some extra debugging information. *)
          Log.debug ~level:2 "\n%s***%s Done type-checking:\n%a"
            Bash.colors.Bash.yellow Bash.colors.Bash.default
            Types.TypePrinter.pdoc
            (KindCheck.KindPrinter.print_kinds_and_facts, env);

          (* Do the final checks (is this the right time?) *)
          ExtraChecks.check_env env;
          env, List.flatten pointss
    in
    type_check env program []
  in

  (* Type-check the implementation. *)
  Log.debug ~level:2 "\n%s***%s Type-checking the implementation of %a, \
      environment so far:\n\n%a"
    Bash.colors.Bash.yellow Bash.colors.Bash.default
    Module.p mname
    Types.TypePrinter.penv env;
  let env, points = type_check env program in

  (* And type-check the implementation against its own signature, if any. *)
  Log.debug ~level:2 "\n%s***%s Matching %a against its signature"
    Bash.colors.Bash.yellow Bash.colors.Bash.default
    Module.p mname;
  let output_env =
    match interface with
    | Some interface ->
        let exports = List.map (fun p ->
          let k = Types.get_kind env p in
          let name =
            Option.extract (Hml_List.find_opt (function
              | Types.User (mname, x) when Module.equal mname env.Types.module_name ->
                 Some x
              | _ ->
                 assert false
            ) (Types.get_names env p))
          in
          name, k, p
        ) points in
        (* If the function types are not syntactically equal, the decision
         * procedure for comparing those two types introduces internal names
         * that end polluting the resulting environment! So we only use that
         * "polluted" environment to perform interface-checking, we don't
         * actually return it to the driver, say, for printing. *)
        check_interface env interface exports
    | None ->
        env
  in

  (* Check that the implementation leaves all other modules intact (matching
   * against the signature right above may have consumed permissions from other
   * modules!) *)
  Log.debug ~level:2 "\n%s***%s Checking %a does not alter other interfaces"
    Bash.colors.Bash.yellow Bash.colors.Bash.default
    Module.p mname;
  List.iter (fun mname ->
    let iface = find_and_lex_interface mname in
    (* Ignore the interface, since there's no risk of an interface consuming
     * another interface's contents! Moreover, this can be a risk: since
     * [check_interface] has the nasty consequence that the [env] it returns is
     * polluted with internal names (the result of performing calls to
     * [Permissions.sub]), opening the same module twice may cause conflicts... *)
    let exports = Types.get_exports env mname in
    ignore (check_interface output_env iface exports)
  ) deps;

  env
;;


let just_print_interface (mname: Module.name) =

  let env = Types.empty_env in

  (* Find all the dependencies... *)
  let deps = Modules.all_dependencies mname find_and_lex_interface in
  (* Add our interface at the end. *)
  let deps = deps @ [mname] in

  (* And import them all in scope. *)
  let env = import_dependencies_in_scope env deps in

  env
;;



(* Plug everything together and process a given file. *)
let process file_path =
  if not (Sys.file_exists file_path) then
    Log.error "File %s does not exist" file_path;

  if Filename.check_suffix file_path ".mz" then
    let program = lex_and_parse_implementation file_path in
    let mname = module_name_for_file_path file_path in
    let iface =
      let iface_path = file_path ^ "i" in
      if Sys.file_exists iface_path then
        Some (lex_and_parse_interface iface_path)
      else
        None
    in
    let env = check_implementation mname program iface in
    env
  else if Filename.check_suffix file_path ".mzi" then
    let mname = module_name_for_file_path file_path in
    just_print_interface mname
  else
    Log.error "Unknown file extension"
;;

(* The [run] function servers as a wrapper that catches errors and prints them
 * properly (at the cost of losing a useful backtrace, though). *)
type run_options = {
  html_errors: bool;
}

let run { html_errors } f =
  try
    f ()
  with
  | TypeErrors.TypeCheckerError ((env, _) as e) ->
      if html_errors then begin
        (* Get a plain-text version of the error *)
        Hml_Pprint.disable_colors ();
        let text = Hml_String.bsprintf "%a\n" TypeErrors.print_error e in
        (* Generate the HTML explanation. *)
        Debug.explain ~text env;
        (* Find out about the command to run. *)
        let f = (fst env.Types.location).Lexing.pos_fname in
        let f = Hml_String.replace "/" "_" f in
        let cmd = Printf.sprintf
          "firefox -new-window \"viewer/viewer.html?json_file=data/%s.json\" &"
          f
        in
        (* Let's do it! *)
        ignore (Sys.command cmd)
      end else begin
        Hml_String.beprintf "%a\n" TypeErrors.print_error e;
      end;
      exit 251
  | KindCheck.KindError e ->
      Hml_String.beprintf "%a\n" KindCheck.print_error e;
      exit 250
;;


(* A fancy version of [TypePrinter.penv]. It will *not* generate a valid .mzi
 * file, but it will give a somehow readable version of all the names that have
 * been defined in the environment as well as the type available for them. *)
let print_signature (buf: Buffer.t) (env: Types.env): unit =
  flush stdout;
  flush stderr;
  let open Types in
  let compare_locs loc1 loc2 =
    Lexing.(compare loc1.pos_cnum loc2.pos_cnum)
  in
  let perms = fold_terms env (fun acc point { locations; _ } { permissions; _ } ->
    let locations = List.sort (fun (loc1, _) (loc2, _) -> compare_locs loc1 loc2) locations in
    let location = fst (List.hd locations) in
    List.map (fun x -> point, location, x) permissions :: acc
  ) [] in
  let perms = List.flatten perms in
  let perms = List.filter (fun (point, _, perm) ->
    match perm with
    | TyUnknown ->
        false
    | TySingleton (TyPoint point') when same env point point' ->
        false
    | _ ->
        true
  ) perms in
  let perms = List.sort (fun (_, loc1, _) (_, loc2, _) -> compare_locs loc1 loc2) perms in
  List.iter (fun (point, _, t) ->
    let open TypePrinter in
    let open Hml_Pprint in
    try
      let name = List.find (function
        | User (m, x) ->
            Module.equal m env.module_name &&
            (Variable.print x).[0] <> '/'
        | Auto _ ->
            false
      ) (get_names env point) in
      let t =
        match TypeErrors.fold_type env t with
        | Some t ->
            t
        | None ->
            Log.warn "Badly printed type, sorry about that!";
            t
      in
      pdoc buf ((fun () ->
        let t = print_type env t in
        string "val" ^^ space ^^
        print_var env name ^^ space ^^ at ^^ space ^^ (nest 2 t) ^^
        break1
      ), ())

    with Not_found ->
      ()
  ) perms
;;
