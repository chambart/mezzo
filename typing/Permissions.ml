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

(** This is the core of the type-checker, where we handle the set of available
 * permissions, subtracting a permission from the environment, adding
 * permissions to the environment. *)

open TypeCore
open Types
open TypeErrors

(* -------------------------------------------------------------------------- *)

(* This should help debuggnig. *)

let safety_check env =
  (* Be paranoid, perform an expensive safety check. *)
  if Log.debug_level () >= 5 then
    fold_terms env (fun () var permissions ->
      (* Each term should have exactly one singleton permission. If we fail here,
       * this is SEVERE: this means one of our internal invariants broken, so
       * someone messed up the code somewhere. *)
      let singletons = List.filter (function
        | TySingleton (TyOpen _) ->
            true
        | _ ->
            false
      ) permissions in
      if List.length singletons <> 1 then
        Log.error
          "%a inconsistency detected: not one singleton type for %a\n%a\n"
          Lexer.p (location env)
          TypePrinter.pnames (env, get_names env var)
          TypePrinter.penv env;

      (* The inconsistencies below are suspicious, but it may just be that we
       * failed to mark the environment as inconsistent. *)

      (* Unless the environment is inconsistent, a given type should have no
       * more than one concrete type. It may happen that we fail to detect this
       * situation and mark the environment as inconsistent, so this check will
       * explode, and remind us that this is one more situation that will mark an
       * environment as inconsistent. *)
      let concrete = List.filter (function
        | TyConcreteUnfolded _ ->
            true
        | TyTuple _ ->
            true
        | _ ->
            false
      ) permissions in
      (* This part of the safety check is disabled because it is too restrictive,
       * see [twostructural.mz] for an example. *)
      if false && not (is_inconsistent env) && List.length concrete > 1 then
        Log.error
          "%a inconsistency detected: more than one concrete type for %a\n\
            (did you add a function type without calling \
            [simplify_function_type]?)\n%a\n"
          Lexer.p (location env)
          TypePrinter.pnames (env, get_names env var)
          TypePrinter.penv env;

      let exclusive = List.filter (FactInference.is_exclusive env) permissions in
      if not (is_inconsistent env) && List.length exclusive > 1 then
        Log.error
          "%a inconsistency detected: more than one exclusive type for %a\n%a\n"
          Lexer.p (location env)
          TypePrinter.pnames (env, get_names env var)
          TypePrinter.penv env;
    ) ()
;;


(* -------------------------------------------------------------------------- *)

(* Dealing with floating permissions.
 *
 * Floating permissions are permission variables that are available in the
 * environment. They may be abstract or flexible, but in any case, we can't
 * attach them to an identifier, since they're variables. Therefore, they are
 * treated differently. The various [add_perm] and [sub_perm] function will case
 * these two helpers. *)


let add_floating_perm env t =
  let floating_permissions = get_floating_permissions env in
  set_floating_permissions env (t :: floating_permissions)
;;


(* -------------------------------------------------------------------------- *)

let add_hint hint str =
  match hint with
  | Some (Auto n)
  | Some (User (_, n)) ->
      Some (Auto (Variable.register (Variable.print n ^ "_" ^ str)))
  | None ->
      None
;;

(** [collect t] returns all the permissions contained in [t] along with the
 * "cleaned up" version of [t]. *)
let collect = TypeOps.collect;;


(* -------------------------------------------------------------------------- *)

(* For adding new constraints into the environment. *)
let add_constraints env constraints =
  let env = List.fold_left (fun env (f, t) ->
    let f = fact_of_flag f in
    match t with
    | TyOpen p ->
        let f' = get_fact env p in
        if fact_leq f f' then
        (* [f] tells, for instance, that [p] be exclusive *)
          set_fact env p f
        else
          env
    | _ ->
        Log.error "FIXME"
  ) env constraints in
  env
;;


let perm_not_flex env t =
  match modulo_flex env t with
  | TyAnchoredPermission (x, _) ->
      not (is_flexible env !!x)
  | TyOpen p ->
      not (is_flexible env p)
  | TyStar _ ->
      true
  | TyEmpty ->
      true
  | TyApp _ ->
      true
  | _ ->
      Log.error "You should not call [perm_not_flex] on %a"
        TypePrinter.ptype (env, t)
;;

(** Wraps "t1" into "∃x.(=x|x@t1)". This is really useful because if this is
 * meant to be added afterwards, then [t1] will be added in expanded form with a
 * free call to [unfold]! *)
let wrap_bar t1 =
  let binding = Auto (Utils.fresh_var "sp"), KTerm, location empty_env in
  TyExists (binding,
    TyBar (
      TySingleton (TyBound 0),
      TyAnchoredPermission (TyBound 0, DeBruijn.lift 1 t1)
    )
  )
;;

type side = Left | Right

let is_singleton env t =
  match modulo_flex env t with
  | TySingleton _ -> true
  | TyBar (TySingleton _, _) -> true
  | _ -> false
;;

(** This function opens all rigid quantifications inside a type to make sure we
 * don't open up a binding too late. When [side] is [Left], existential bindings
 * are opened as rigid variables; when [side] is [Right], universal bindings are
 * opened as rigid variables. This operation is useful in [sub_type], before
 * we're about to change levels.
 *
 * This function actually does quite a bit of work, in the sense that it
 * performs unfolding on demand: if there is a missing structure point that
 * could potentially be a rigid variable, it creates it... *)
let rec open_all_rigid_in (env: env) (t: typ) (side: side): env * typ =
  match t with
  | TyUnknown
  | TyDynamic
  | TyBound _
  | TyOpen _ ->
      env, t

  | TyForall ((binding, _), t1) ->
      if side = Right then
        let env, t1, _ = bind_rigid_in_type env binding t1 in
        let env, t1 = open_all_rigid_in env t1 side in
        env, t1
      else
        env, t

  | TyExists (binding, t1) ->
      if side = Left then
        let env, t1, _ = bind_rigid_in_type env binding t1 in
        let env, t1 = open_all_rigid_in env t1 side in
        env, t1
      else
        env, t

  | TyApp _ ->
      env, t

  | TyTuple ts ->
      let env, ts = List.fold_left (fun (env, acc) t ->
        let t =
          if not (is_singleton env t) then wrap_bar t
          else t
        in
        let env, t = open_all_rigid_in env t side in
        env, t :: acc
      ) (env, []) ts in
      let ts = List.rev ts in
      env, TyTuple ts

  | TyConcreteUnfolded (d, fields, clause) ->
      let env, fields = List.fold_left (fun (env, acc) field ->
        match field with
        | FieldValue (f, t) ->
            let t =
              if not (is_singleton env t) then wrap_bar t
              else t
            in
            let env, t = open_all_rigid_in env t side in
            env, FieldValue (f, t) :: acc
        | FieldPermission t ->
            let env, t = open_all_rigid_in env t side in
            env, FieldPermission t :: acc
      ) (env, []) fields in
      let fields = List.rev fields in
      env, TyConcreteUnfolded (d, fields, clause)

  | TySingleton _ ->
      env, t

  | TyArrow (t1, t2) ->
      (* This is subtle! Existentials in the codomain are universal! *)
      begin match side with
      | Right ->
          let env, t1 = open_all_rigid_in env t1 Left in
          env, TyArrow (t1, t2)
      | Left ->
          env, t
      end

  | TyBar (t1, t2) ->
      let env, t1 = open_all_rigid_in env t1 side in
      let env, t2 = open_all_rigid_in env t2 side in
      env, TyBar (t1, t2)

  | TyAnchoredPermission (t1, t2) ->
      let env, t1 = open_all_rigid_in env t1 side in
      let env, t2 = open_all_rigid_in env t2 side in
      env, TyAnchoredPermission (t1, t2)

  | TyEmpty ->
      env, t

  | TyStar (t1, t2) ->
      let env, t1 = open_all_rigid_in env t1 side in
      let env, t2 = open_all_rigid_in env t2 side in
      env, TyStar (t1, t2)

  | TyAnd (ds, t) ->
      let env, t = open_all_rigid_in env t side in
      env, TyAnd (ds, t)

  | TyImply (ds, t) ->
      let env, t = open_all_rigid_in env t side in
      env, TyImply (ds, t)
;;


(** [unify env p1 p2] merges two vars, and takes care of dealing with how the
    permissions should be merged. *)
let rec unify (env: env) (p1: var) (p2: var): env =
  Log.check (is_term env p1 && is_term env p2) "[unify p1 p2] expects [p1] and \
    [p2] to be variables with kind term, not type";

  if same env p1 p2 then
    env
  else if is_flexible env p2 then
    instantiate_flexible env p2 (TyOpen p1)
  else if is_flexible env p1 then
    instantiate_flexible env p1 (TyOpen p2)
  else
   (* We need to first merge the environment, otherwise this will go into an
     * infinite loop when hitting the TySingletons... *)
    let perms = get_permissions env p2 in
    let env = merge_left env p1 p2 in
    List.fold_left (fun env t -> add env p1 t) env perms

and keep_only_duplicable env =
  let env = fold_terms env (fun env var permissions ->
    let permissions = List.filter (FactInference.is_duplicable env) permissions in
    let env = set_permissions env var permissions in
    env
  ) env in

  (* Don't forget the abstract perm variables. *)
  let floating = get_floating_permissions env in
  let floating = List.filter (FactInference.is_duplicable env) floating in
  let env = set_floating_permissions env floating in

  env


(** [add env var t] adds [t] to the list of permissions for [p], performing all
    the necessary legwork. *)
and add (env: env) (var: var) (t: typ): env =
  Log.check (is_term env var) "You can only add permissions to a var that \
    represents a program identifier.";

  let t = modulo_flex env t in

  let hint = get_name env var in

  (* We first perform unfolding, so that constructors with one branch are
   * simplified. [unfold] calls [add] recursively whenever it adds new vars. *)
  let env, t = unfold env ~hint t in

  (* Break up this into a type + permissions. *)
  let t, perms = collect t in

  TypePrinter.(Log.debug ~level:4 "%s[%sadding to %a] %a"
    Bash.colors.Bash.red Bash.colors.Bash.default
    pnames (env, get_names env var)
    ptype (env, t));

  (* Add the permissions. *)
  let env = List.fold_left add_perm env perms in

  begin match t with
  | TySingleton (TyOpen p) when not (same env var p) ->
      Log.debug ~level:4 "%s]%s (singleton)" Bash.colors.Bash.red Bash.colors.Bash.default;
      unify env var p

  | TyExists (binding, t) ->
      Log.debug ~level:4 "%s]%s (exists)" Bash.colors.Bash.red Bash.colors.Bash.default;
      begin match binding with
      | _, KTerm, _ ->
          let env, t, _ = bind_rigid_in_type env binding t in
          add env var t
      | _ ->
          Log.error "I don't know how to deal with an existentially-quantified \
            type or permission";
      end

  | TyAnd (constraints, t) ->
      Log.debug ~level:4 "%s]%s (and-constraints)" Bash.colors.Bash.red Bash.colors.Bash.default;
      let env = add_constraints env constraints in
      add env var t

  (* This implement the rule "x @ (=y, =z) * x @ (=y', =z') implies y = y' and z * = z'" *)
  | TyConcreteUnfolded (dc, ts, clause) ->
      let original_perms = get_permissions env var in
      begin match Hml_List.find_opt (function
        | TyConcreteUnfolded (dc', ts', clause') when resolved_datacons_equal env dc dc' ->
            Some (ts', clause')
        | _ -> None)
        original_perms
      with
      | Some (ts', clause') ->
          begin match
            sub_type env clause clause' >>= fun env ->
            sub_type env clause' clause
          with
          | _ when FactInference.is_exclusive env t ->
              mark_inconsistent env
          | None ->
              (* Incompatible "adopts" clauses. *)
              mark_inconsistent env
          | Some env ->
              List.fold_left2 (fun env f1 f2 ->
                match f1, f2 with
                | FieldValue (f, t), FieldValue (f', t') when Field.equal f f' ->
                    begin match modulo_flex env t with
                    | TySingleton (TyOpen p) ->
                        add env p t'
                    | _ ->
                        Log.error "Type not unfolded"
                    end
                | _ ->
                    Log.error "Datacon order invariant not respected"
              ) env ts ts'
          end
      | None ->
          add_type env var t
      end

  | TyTuple ts ->
      let original_perms = get_permissions env var in
      begin match Hml_List.find_opt (function TyTuple ts' -> Some ts' | _ -> None) original_perms with
      | Some ts' ->
          if List.length ts <> List.length ts' then
            mark_inconsistent env
          else
            List.fold_left2 (fun env t t' ->
              match modulo_flex env t with
              | TySingleton (TyOpen p) ->
                  add env p t'
              | _ ->
                  Log.error "Type not unfolded"
            ) env ts ts'
      | None ->
          add_type env var t
      end


  | _ ->
      (* Add the "bare" type. Recursive calls took care of calling [add]. *)
      let env = add_type env var t in
      safety_check env;

      env
  end


(** [add_perm env t] adds a type [t] with kind KPerm to [env], returning the new
    environment. *)
and add_perm (env: env) (t: typ): env =
  Log.check (get_kind_for_type env t = KPerm) "This function only works with types of kind perm.";
  if t <> TyEmpty then
    TypePrinter.(Log.debug ~level:4 "[add_perm] %a" ptype (env, t));

  match modulo_flex env t with
  | TyAnchoredPermission (p, t) ->
      Log.check (not (is_flexible env !!p))
        "Do NOT add a permission whose left-hand-side is flexible.";
      add env !!p t
  | TyStar (p, q) ->
      add_perm (add_perm env p) q
  | TyEmpty ->
      env
  | _ ->
      add_floating_perm env t


and add_perm_raw env p t =
  let permissions = get_permissions env p in
  set_permissions env p (t :: permissions)

(* [add_type env p t] adds [t], which is assumed to be unfolded and collected,
 * to the list of available permissions for [p] *)
and add_type (env: env) (p: var) (t: typ): env =
  match Log.silent (fun () -> sub env p t) with
  | Some _ ->
      (* We're not re-binding env because this has bad consequences: in
       * particular, when adding a flexible type variable to a var, it
       * instantiates it into, say, [=x], which is usually *not* what we want to
       * do. Happens mostly when doing higher-order, see impredicative.mz or
       * list-map2.mz for examples. *)
      Log.debug ~level:4 "→ sub worked%s]%s" Bash.colors.Bash.red Bash.colors.Bash.default;
      let in_there_already =
        List.exists (fun x -> equal env x t) (get_permissions env p)
      in
      if FactInference.is_exclusive env t then begin
        (* If [t] is exclusive, then this makes the environment inconsistent. *)
        Log.debug ~level:4 "%sInconsistency detected%s, adding %a as an exclusive \
            permission, but it's already available."
          Bash.colors.Bash.red Bash.colors.Bash.default
          TypePrinter.ptype (env, t);
        mark_inconsistent env
      end else if FactInference.is_duplicable env t && in_there_already then
        env
      else
        (* Either the type is not duplicable (so we need to add it!), or it is
         * duplicable, but doesn't exist per se (e.g. α flexible with
         * [duplicable α]) in the permission list. Add it. *)
        add_perm_raw env p t
  | None ->
      Log.debug ~level:4 "→ sub did NOT work%s]%s" Bash.colors.Bash.red Bash.colors.Bash.default;
      let env = add_perm_raw env p t in
      (* If we just added an exclusive type to the var, then it automatically
       * gains the [dynamic] type. *)
      if FactInference.is_exclusive env t then
        add_type env p TyDynamic
      else
        env


(** [unfold env t] returns [env, t] where [t] has been unfolded, which
    potentially led us into adding new vars to [env]. The [hint] serves when
    making up names for intermediary variables. *)
and unfold (env: env) ?(hint: name option) (t: typ): env * typ =
  (* This auxiliary function takes care of inserting an indirection if needed,
   * that is, a [=foo] type with [foo] being a newly-allocated [var]. *)
  let insert_var (env: env) ?(hint: name option) (t: typ): env * typ =
    let hint = Option.map_none (fresh_auto_var "t_") hint in
    match t with
    | TySingleton _ ->
        env, t
    | _ ->
        (* The [expr_binder] also serves as the binder for the corresponding
         * term type variable. *)
        let env, p = bind_rigid env (hint, KTerm, location env) in
        (* This will take care of unfolding where necessary. *)
        let env = add env p t in
        env, ty_equals p
  in

  let rec unfold (env: env) ?(hint: name option) (t: typ): env * typ =
    let t = modulo_flex env t in
    match t with
    | TyUnknown
    | TyDynamic
    | TySingleton _
    | TyArrow _
    | TyEmpty ->
        env, t

    | TyOpen _
    | TyApp _ ->
        begin match expand_if_one_branch env t with
        | TyConcreteUnfolded _ as t->
            unfold env t
        | _ ->
            env, t
        end

    | TyBound _ ->
        Log.error "No unbound variables allowed here"

    | TyForall _
    | TyExists _ ->
        env, t

    | TyStar _ ->
        env, t

    | TyBar (t, p) ->
        let env, t = unfold env ?hint t in
        env, TyBar (t, p)

    | TyAnchoredPermission _ ->
        env, t

    (* We're only interested in unfolding structural types. *)
    | TyTuple components ->
        let env, components = Hml_List.fold_lefti (fun i (env, components) component ->
          let hint = add_hint hint (string_of_int i) in
          let env, component = insert_var env ?hint component in
          env, component :: components
        ) (env, []) components in
        env, TyTuple (List.rev components)

    | TyConcreteUnfolded (datacon, fields, clause) ->
        (* If this is a user-provided type (e.g. a function parameter's type) we
         * should not blindly accept this type when adding it into our
         * environment. *)
        let all_fields_there =
          let _, def, _ = def_for_datacon env datacon in
          let _, branch = List.find (fun (datacon', _) -> Datacon.equal (snd datacon) datacon') def in
          let field_name = function
            | FieldValue (name, _) -> Some name
            | FieldPermission _ -> None
          in
          let fields' = Hml_List.map_some field_name branch in
          let fields = Hml_List.map_some field_name fields in
          List.length fields = List.length fields' &&
          List.for_all (fun field' ->
            List.exists (Field.equal field') fields
          ) fields'
        in
        if not (all_fields_there) then
          raise_error env (FieldMismatch (t, (snd datacon)));
        (* It's fine, add it! *)
        let env, fields = List.fold_left (fun (env, fields) -> function
          | FieldPermission _ as field ->
              env, field :: fields
          | FieldValue (name, field) ->
              let hint =
                add_hint hint (Hml_String.bsprintf "%a_%a" Datacon.p (snd datacon) Field.p name)
              in
              let env, field = insert_var env ?hint field in
              env, FieldValue (name, field) :: fields
        ) (env, []) fields
        in
        env, TyConcreteUnfolded (datacon, List.rev fields, clause)

    | TyAnd _
    | TyImply _ ->
        env, t

  in
  unfold env ?hint t


(** [sub env var t] tries to extract [t] from the available permissions for
    [var] and returns, if successful, the resulting environment. This is one of
    the two "sub" entry points that this module exports.*)
and sub (env: env) (var: var) (t: typ): env option =
  Log.check (is_term env var) "You can only subtract permissions from a var \
    that represents a program identifier.";

  let t = modulo_flex env t in

  if is_inconsistent env then
    Some env

  else if is_singleton env t then
    sub_type env (ty_equals var) t

  else
    let permissions = get_permissions env var in

    (* Priority-order potential merge candidates. *)
    let sort = function
      | _ as t when not (FactInference.is_duplicable env t) -> 0
      (* This basically makes sure we never instantiate a flexible variable with a
       * singleton type. The rationale is that we're too afraid of instantiating
       * with something local to a branch, which will then make the [Merge]
       * operation fail (see [merge18.mz] and [merge19.mz]). *)
      | TySingleton _ -> 3
      | TyUnknown -> 2
      | _ -> 1
    in
    let sort x y = sort x - sort y in
    let permissions = List.sort sort permissions in


    (* [take] proceeds left-to-right *)
    match Hml_List.take (fun x -> sub_type env x t) permissions with
    | Some (remaining, (t_x, env)) ->
        (* [t_x] is the "original" type found in the list of permissions for [x].
         * -- see [tests/fact-inconsistency.mz] as to why I believe it's correct
         * to check [t_x] for duplicity and not just [t]. *)
        if FactInference.is_duplicable env t_x then
          Some env
        else
          Some (set_permissions env var remaining)
    | None ->
        None



and sub_constraints env constraints =
  List.fold_left (fun env (f, t) ->
    env >>= fun env ->
    let f = fact_of_flag f in
    (* [t] can be any type; for instance, if we have
     *  f @ [a] (duplicable a) ⇒ ...
     * then, when "f" is instantiated, "a" will be replaced by anything...
     *)
    let f' = FactInference.analyze_type env t in
    let is_ok = fact_leq f' f in
    Log.debug "fact [is_ok=%b] for %a: %a"
      is_ok
      TypePrinter.ptype (env, t) TypePrinter.pfact f';
    (* [f] demands, for instance, that [p] be exclusive *)
    if is_ok then
      Some env
    else
      None
  ) (Some env) constraints


(** When comparing "list (a, b)" with "list (a*, b* )" you need to compare the
 * parameters, but for that, unfolding first is a good idea. This is one of the
 * two "sub" entry points that this module exports. *)
and sub_type_with_unfolding (env: env) (t1: typ) (t2: typ): env option =
  (* We basically turn both [t1] and [t2] into "∃x.(=x | x @ t1)" which will
   * perform the right dance, including unfolding, thanks to our excellent
   * [add_sub] algorithm (self-pat on the back). *)
  sub_type env (wrap_bar t1) (wrap_bar t2)


(** [sub_type env t1 t2] examines [t1] and, if [t1] "provides" [t2], returns
    [Some env] where [env] has been modified accordingly (for instance, by
    unifying some flexible variables); it returns [None] otherwise.
    
    BEWARE: this is *not* the function that is exported as "sub_type". We export
    "sub_type_with_unfolding" as "sub_type". *)
and sub_type (env: env) (t1: typ) (t2: typ): env option =
  TypePrinter.(
    Log.debug ~level:4 "[sub_type] %a %s—%s %a"
      ptype (env, t1)
      Bash.colors.Bash.red Bash.colors.Bash.default
      ptype (env, t2));

  let t1 = modulo_flex env t1 and t2 = modulo_flex env t2 in

  match t1, t2 with

  (** Trivial case. *)
  | _, _ when equal env t1 t2 ->
      Log.debug ~level:5 "↳ fast-path";
      Some env

  (** Easy cases involving flexible variables *)
  | TyOpen v1, _ when is_flexible env v1 ->
      Some (instantiate_flexible env v1 t2)
  | _, TyOpen v2 when is_flexible env v2 ->
      Some (instantiate_flexible env v2 t1)

  (** Duplicity constraints. *)

  | TyAnd _, _ ->
      Log.error "Constraints should've been processed when this permission was added"

  | TyImply (constraints, t1), t2 ->
      sub_type env t1 (TyAnd (constraints, t2))

  | _, TyAnd (constraints, t2) ->
      (* First do the subtraction, because the constraint may be "duplicable α"
       * with "α" being flexible. *)
      sub_type env t1 t2 >>= fun env ->
      (* And then, hoping that α has been instantiated, check that it satisfies
       * the constraint. *)
      sub_constraints env constraints

  | t1, TyImply (constraints, t2) ->
      let env = add_constraints env constraints in
      sub_type env t1 t2


  (** Higher priority for binding rigid = universal quantifiers. *)

  | _, TyForall ((binding, _), t2) ->
      let env, t2, _ = bind_rigid_in_type env binding t2 in
      sub_type env t1 t2

  | TyExists (binding, t1), _ ->
      let env, t1, _ = bind_rigid_in_type env binding t1 in
      sub_type env t1 t2


  (** Lower priority for binding flexible = existential quantifiers. *)

  | TyForall ((binding, _), t1), _ ->
      let env, t2 = open_all_rigid_in env t2 Right in
      let env, t1, _ = bind_flexible_in_type env binding t1 in
      sub_type env t1 t2

  | _, TyExists (binding, t2) ->
      let env, t1 = open_all_rigid_in env t1 Left in
      let env, t2, _ = bind_flexible_in_type env binding t2 in
      sub_type env t1 t2


  (** Structural rules *)

  | TyTuple components1, TyTuple components2
    when List.length components1 = List.length components2 ->
      List.fold_left2 (fun env t1 t2 ->
        env >>= fun env ->
        match t1, t2 with
        | TySingleton (TyOpen p1), _ when is_flexible env p1 ->
            (* The unfolding never, ever introduces flexible variables. *)
            assert false
        | TySingleton (TyOpen p1), TySingleton (TyOpen p2) when is_flexible env p2 ->
            (* This is a fast-path that creates less debug output and makes
             * things easier to understand when reading traces. *)
            Some (merge_left env p1 p2)
        | TySingleton (TyOpen p1), _ ->
            (* “=x - τ” can always be rephrased as “take τ from the list of
             * available permissions for x” by replacing “τ” with
             * “∃x'.(=x'|x' @ τ)” and instantiating “x'” with “x”. *)
            sub env p1 t2
        | _ ->
            None
      ) (Some env) components1 components2

  | TyConcreteUnfolded (datacon1, fields1, clause1), TyConcreteUnfolded (datacon2, fields2, clause2)
    when List.length fields1 = List.length fields2 ->
      if resolved_datacons_equal env datacon1 datacon2 then
        sub_type env clause1 clause2 >>= fun env ->
        List.fold_left2 (fun env f1 f2 ->
          env >>= fun env ->
          let t1, t2 =
            match f1, f2 with
            | FieldValue (name1, t1), FieldValue (name2, t2) ->
                Log.check (Field.equal name1 name2) "Not in order?";
                t1, t2
            | _ ->
                Log.error "The type we're trying to extract should've been \
                  cleaned first."
          in
          (* This is the same logic as the [TyTuple] case above, scroll up for
           * comments and detailed explanations as to why these rules are
           * correct. *)
          match t1, t2 with
          | TySingleton (TyOpen p1), _ when is_flexible env p1 ->
              assert false
          | TySingleton (TyOpen p1), TySingleton (TyOpen p2) when is_flexible env p2 ->
              Some (merge_left env p1 p2)
          | TySingleton (TyOpen p1), _ ->
              sub env p1 t2
          | _ ->
              None
        ) (Some env) fields1 fields2

      else
        None

  | TyConcreteUnfolded ((cons1, datacon1), _, _), TyApp (cons2, args2) ->
      let var1 = !!cons1 in
      let cons2 = !!cons2 in

      if same env var1 cons2 then begin
        let datacon2, fields2, clause2 = find_and_instantiate_branch env cons2 datacon1 args2 in
        (* There may be permissions attached to this branch. *)
        let t2 = TyConcreteUnfolded (datacon2, fields2, clause2) in
        let t2, p2 = collect t2 in
        sub_type env t1 t2 >>= fun env ->
        sub_perms env p2
      end else begin
        None
      end

  | TyConcreteUnfolded ((cons1, datacon1), _, _), TyOpen var2 ->
      (* This is basically the same as above, except that type applications
       * without parameters are not [TyApp]s, they are [TyOpen]s. *)
      let var1 = !!cons1 in

      if same env var1 var2 then begin
        (* XXX why are we not collecting permissions here? *)
        let datacon2, fields2, clause2 = find_and_instantiate_branch env var2 datacon1 [] in
        sub_type env t1 (TyConcreteUnfolded (datacon2, fields2, clause2))
      end else begin
        None
      end

  | TyApp (cons1, args1), TyApp (cons2, args2) ->
      let cons1 = !!cons1 in
      let cons2 = !!cons2 in

      if same env cons1 cons2 then
        (* We enter a potentially non-linear context here. Only keep duplicable
         * parts. *)
        let sub_env = keep_only_duplicable env in
        Hml_List.fold_left2i (fun i sub_env arg1 arg2 ->
          sub_env >>= fun sub_env ->
          (* Variance comes into play here as well. The behavior is fairly
           * intuitive. *)
          match variance sub_env cons1 i with
          | Covariant ->
              sub_type_with_unfolding sub_env arg1 arg2
          | Contravariant ->
              sub_type_with_unfolding sub_env arg2 arg1
          | Bivariant ->
              Some sub_env
          | Invariant ->
              sub_type_with_unfolding sub_env arg1 arg2 >>= fun sub_env ->
              sub_type_with_unfolding sub_env arg2 arg1
        ) (Some sub_env) args1 args2 >>= fun sub_env ->
        Some (import_flex_instanciations env sub_env)
      else
        None

  | TySingleton t1, TySingleton t2 ->
      sub_type env t1 t2

  | TyArrow (t1, t2), TyArrow (t'1, t'2) ->
      (* This rule basically amounts to performing an η-expansion on function
       * types. Therefore, we strip the environment of its duplicable parts and
       * keep only the instanciations when returning the final result. *)

      (* 1) Check facts as late as possible (the instantiation of a flexible
       * variables may happen only in "t2 - t'2"). *)
      let env, t1, constraints = match t1 with
        | TyAnd (constraints, t1) ->
            env, t1, constraints
        | _ ->
            env, t1, []
      in

      (* We perform implicit eta-expansion, so again, non-linear context (we're
       * under an arrow). *)
      let sub_env = keep_only_duplicable env in

      (* 2) Let us compare the domains... *)
      Log.debug ~level:4 "%sArrow / Arrow, left%s"
        Bash.colors.Bash.red
        Bash.colors.Bash.default;
      sub_type sub_env t'1 t1 >>= fun sub_env ->

      (* 3) And let us compare the codomains... *)
      Log.debug ~level:4 "%sArrow / Arrow, right%s"
        Bash.colors.Bash.red
        Bash.colors.Bash.default;
      sub_type sub_env t2 t'2 >>= fun sub_env ->

      (* 3b) Now check facts! *)
      Log.debug ~level:4 "%sArrow / Arrow, facts%s"
        Bash.colors.Bash.red
        Bash.colors.Bash.default;
      sub_constraints sub_env constraints >>= fun sub_env ->

      (* 4) We have successfully compared these function types. Just return the
       * "restored" sub_environment, that is, the sub_environment with the exact same
       * set of original permissions, except that the unifications that took
       * place are now retained. *)
      Log.debug ~level:4 "%sArrow / End -- adding back permissions%s"
        Bash.colors.Bash.red
        Bash.colors.Bash.default;

      Some (import_flex_instanciations env sub_env)

  | TyBar _, TyBar _ ->
      (* Unless we do this, we can't handle (t|p) - (t|p|p') properly. *)
      let t1, ps1 = collect t1 in
      let t2, ps2 = collect t2 in

      (* This has the nice guarantee that we don't need to worry about flexible
       * PERM variables anymore (hence the call to List.partition a few lines
       * below). *)
      let ps1 = Hml_List.map_flatten (flatten_star env) ps1 in
      let ps2 = Hml_List.map_flatten (flatten_star env) ps2 in

      (* "(t1 | p1) - (t2 | p2)" means doing "t1 - t2", adding all of [p1],
       * removing all of [p2]. However, the order in which we perform these
       * operations matters, unfortunately. *)
      Log.debug ~level:4 "[add_sub] entering...";

      (*  All these manipulations are required when doing higher-order, because
       * we need to compare function types, and function types have complicated
       * [TyBar]s for their arguments and return values.
       *  [p1] and [p2] contain permissions such as “x @ τ” where “x” is
       * flexible. Therefore, we need to pick permissions that we know how to
       * add or subtract, that is, permissions for which “x” is rigid.
       *  The algorithm below becomes even more complicated because we need to
       * be smart when [p1] or [p2] contain flexible permission variables: we
       * need to instantiate these in a smart way.
       *  The first step consists in subtracting [t2] from [t1], as most of the
       * time, we're dealing with “(=x|...) - (=x'|...)”. *)
      sub_type env t1 t2 >>= fun env ->

      (*   [add_perm] will fail if we add "x @ t" when "x" is flexible. So we
       * search among the permissions in [ps1] one that is suitable for adding,
       * i.e. a permission whose left-hand-side is not flexible.
       *   But we may be stuck because all permissions in [ps1] have their lhs
       * flexible! However, maybe there's an element in [ps2] that, when
       * subtracted, "unlocks" the situation by instantiating the lhs of one
       * permission in [ps1]. So we alternate adding from [ps1] and subtracting
       * from [ps2] until there's nothing left we can do, either because
       * something's flexible, or because the permissions can't be subtracted. *)
      let works_for_add = perm_not_flex in
      let works_for_sub env p2 = perm_not_flex env p2 && Option.is_some (sub_perm env p2) in

      (* This is the main function. *)
      let rec add_sub env ps1 ps2: env * typ list * typ list =
        match Hml_List.take_bool (works_for_add env) ps1 with
        | Some (ps1, p1) ->
            let env = add_perm env p1 in
            add_sub env ps1 ps2
        | None ->
            match Hml_List.take_bool (works_for_sub env) ps2 with
            | Some (ps2, p2) ->
                let env = Option.extract (sub_perm env p2) in
                add_sub env ps1 ps2
            | None ->
                env, ps1, ps2
      in

      (* Our new strategy for inferring PERM variables is as follows. We first
       * put the PERM variables aside, perform the add/sub dance, and see what's
       * left. If either side is made up of just one flexible PERM variable,
       * then bingo, we win.
       *
       * FIXME: this works very well when the flexible variable is in [vars1]; when
       * it is in [vars2], chances are, we've added everything from [ps1] into
       * the environment, so we don't know what's left for us to instanciate
       * [ps2] with... first try a syntactic criterion? Only add permissions in
       * [ps1] if they “unlock” something in [ps2]? I don't know... *)
      let vars1, ps1 = List.partition (function TyOpen _ -> true | _ -> false) ps1 in
      let vars2, ps2 = List.partition (function TyOpen _ -> true | _ -> false) ps2 in

      Log.debug ~level:4 "[add_sub] starting with ps1=%a, ps2=%a, vars1=%a, vars2=%a"
        TypePrinter.ptype (env, fold_star ps1)
        TypePrinter.ptype (env, fold_star ps2)
        TypePrinter.ptype (env, fold_star vars1)
        TypePrinter.ptype (env, fold_star vars2);

      (* Try to eliminate as much as we can... *)
      let env, ps1, ps2 = Log.silent (fun () -> add_sub env ps1 ps2) in

      Log.debug ~level:4 "[add_sub] ended up with ps1=%a, ps2=%a, vars1=%a, vars2=%a"
        TypePrinter.ptype (env, fold_star ps1)
        TypePrinter.ptype (env, fold_star ps2)
        TypePrinter.ptype (env, fold_star vars1)
        TypePrinter.ptype (env, fold_star vars2);

      (* And then try to be smart with whatever remains. *)
      begin match vars1 @ ps1, vars2 @ ps2 with
      | [TyOpen var1 as t1], [TyOpen var2 as t2] ->
          (* Beware! We're doing our own one-on-one matching of permission
           * variables, but still, we need to keep [var1] if it happens to be a
           * duplicable one! So we add it here, and [sub_floating_perm] will
           * remove it or not, depending on the associated fact. *)
          let env = add_floating_perm env t1 in
          begin match is_flexible env var1, is_flexible env var2 with
          | true, false ->
              Some (merge_left env var2 var1)
          | false, true ->
              Some (merge_left env var1 var2)
          | true, true ->
              Some (merge_left env var1 var2)
          | false, false ->
              if same env var1 var2 then
                Some env
              else
                None
          end >>= fun env ->
          sub_floating_perm env t2
      | ps1, [TyOpen var2] when is_flexible env var2 ->
          Some (instantiate_flexible env var2 (fold_star ps1))
      | [TyOpen var1], ps2 when is_flexible env var1 ->
          Some (instantiate_flexible env var1 (fold_star ps2))
      | ps1, [] ->
          (* We may have a remaining, rigid, floating permission. Good for us! *)
          Some (add_perm env (fold_star ps1))
      | [], ps2 ->
          (* This is useful if [ps2] is a rigid floating permission, alone, that
           * also happens to be present in our environment. *)
          sub_perms env ps2
      | _, _ ->
          Log.debug ~level:4 "[add_sub] FAILED";
          None
      end

  | TyBar _, t2 ->
      sub_type env t1 (TyBar (t2, TyEmpty))

  | t1, TyBar _ ->
      sub_type env (TyBar (t1, TyEmpty)) t2

  | TySingleton t1, t2 ->
      let var = !!t1 in
      let perms = List.filter (fun x ->
        match modulo_flex env x with TySingleton _ -> false | _ -> true
      ) (get_permissions env var) in
      Hml_List.find_opt (fun t1 -> sub_type env t1 t2) perms

  | _ ->
      None


(** [sub_perm env t] takes a type [t] with kind KPerm, and tries to return the
    environment without the corresponding permission. *)
and sub_perm (env: env) (t: typ): env option =
  Log.check (get_kind_for_type env t = KPerm) "This type does not have kind perm";
  if t <> TyEmpty then
    TypePrinter.(Log.debug ~level:4 "[sub_perm] %a" ptype (env, t));

  match modulo_flex env t with
  | TyAnchoredPermission (TyOpen p, t) ->
      sub env p t
  | TyStar _ ->
      sub_perms env (flatten_star env t)
  | TyEmpty ->
      Some env
  | _ ->
      sub_floating_perm env t

and sub_perms env perms =
  (* The order in which we subtract a bunch of permission is important because,
   * again, some of them may have their lhs flexible. Therefore, there is a
   * small search procedure here that picks a suitable permission for
   * subtracting. *)
  if List.length perms = 0 then
    Some env
  else
    match Hml_List.take_bool (perm_not_flex env) perms with
    | Some (perms, perm) ->
        sub_perm env perm >>= fun env ->
        sub_perms env perms
    | None ->
        Log.debug ~level:4 "[sub_perms] failed, remaining: %a"
          TypePrinter.ptype (env, fold_star perms);
        None

and sub_floating_perm env t =
  match Hml_List.take (sub_type env t) (get_floating_permissions env) with
  | Some (remaining_perms, (t', env)) ->
      if FactInference.is_duplicable env t' then
        Some env
      else
        Some (set_floating_permissions env remaining_perms)
  | None ->
      None
;;

(** The version we export is actually the one with unfolding baked in. This is
 * the only one the client should use because it makes sure our invariants are
 * respected. *)
let sub_type = sub_type_with_unfolding;;
