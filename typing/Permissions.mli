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

(** This module provides permission manipulation functions. *)

open TypeCore
open Derivations
open Either

(** The module internally can explore several solutions, but in order not to
 * propagate this complexity outside the [Permissions] module, we chose to pick
 * either an arbitrary solution (along with the corresponding derivation), or an
 * arbitrary failed derivation. *)
type result = ((env * derivation), derivation) either

(** [unify env p1 p2] merges two vars, and takes care of dealing with how the
    permissions should be merged. *)
val unify: env -> var -> var -> env

(** [add env var t] adds [t] to the list of permissions for [p], performing all
    the necessary legwork. *)
val add: env -> var -> typ -> env

(** [add_perm env t] adds a type [t] with kind PERM to [env], returning the new
    environment. *)
val add_perm: env -> typ -> env

(** [sub env var t] tries to extract [t] from the available permissions for
    [var] and returns, if successful, the resulting environment. *)
val sub: env -> var -> typ -> result

(** [sub_type env t1 t2] tries to perform [t1 - t2]. It is up to
 * the caller to "do the right thing" by not discarding [t1] if it was not
 * duplicable. Unifications may be performed, hence the return environment. *)
val sub_type: env -> typ -> typ -> result

val sub_perm: env -> typ -> result

val add_hint: (name option) -> string -> (name option)

val sub_constraint: env -> mode_constraint -> result

(** Only keep the duplicable portions of the environment. *)
val keep_only_duplicable: env -> env

(** The safe version of the function found in [TypeCore]. *)
val instantiate_flexible: env -> var -> typ -> env option

(** The safe version of the function found in [TypeCore]. *)
val import_flex_instanciations: env -> env -> env

(** Drop the derivation information and just get an [env option]. *)
val drop_derivation: result -> env option

(**/**)

(** This is for debugging, it runs a consistency check on a given environment. *)
val safety_check: env -> unit
