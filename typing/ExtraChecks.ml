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

(** Various checks that we can't perform until a full environment is ready. *)

open Types
open TypeErrors

let check_adopts_clauses (env: env): unit =
  fold_types env (fun () point _head { definition; _ } ->
    match definition with
    | Some (Some (_, _, Some clause), _) ->
        if not (FactInference.is_exclusive env clause) then
          raise_error env (
            BadFactForAdoptedType (point, clause, FactInference.analyze_type env clause)
          )
    | _ ->
        ()
  ) ()
;;

let check_env (env: env): unit =
  check_adopts_clauses env
;;