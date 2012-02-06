open WellKindedness
open Types

(* ------------------------------------------------------------------------- *)

(* Data structures for the fact inference algorithm. *)

(* Our internal working environment. This is all maps, and their keys are all De
 * Bruijn levels. When navigating inside a data type definition,
 * - the first few levels point to toplevel data type definitions: this is the
 *   [types] field;
 * - the following levels are for the current type's parameters: this is the
 *   [current] field – the first parameter of the type has the lowest level;
 * - all levels after that are for binders we've crossed, for instance a ∀
 *   quantifier: this is the [extra] field. *)
type env = {
  (* Maps global *levels* to knowledge we have acquired so far: the variable
   * name, for debugging; its arity; the corresponding bitfield, if any. *)
  types: (Variable.name * int * state) IndexMap.t;

  (* A bitfield, that maps De Bruijn levels to () if they have to be duplicable.
   * The integer is for the arity of the data type we're currently inspecting. *)
  current: int * bitmap;

  (* This is currently not very useful, but we'll probably need it once we start
   * allowing [foo: ∀(α::term).(duplicable α) => τ]. *)
  extra: var IndexMap.t;

  (* The current De Bruijn level. *)
  level: level;
}

(* When constraining type parameters, we know that:
   - the data type τ is either marked as exclusive or affine, and then we have
   no constraints on its parameters
   - or τ is marked as duplicable, and then some of its parameters are
   duplicable; those are in the [bitmap] *)
and state = fact

and fact = Exclusive | Duplicable of bitmap | Affine

(* This maps levels of the current type parameters to () if that index has to be
 * duplicable, nothing otherwise. *)
and bitmap = unit LevelMap.t

(* The information we know about a variable bound inside a type, with ∀ for
 * instance. This will probably be something like Variable.name * mode in the
 * future. *)
and var = Variable.name

and facts = fact LevelMap.t


(* ------------------------------------------------------------------------- *)

(* Helper functions for working with environments and types. All the functions
 * below take *indexes* as parameters. *)

exception NotDuplicable of typ
(* TEMPORARY this one will have to go eventually *)
exception NotSupported of string

(* [state env i] returns the associated state of the data type with De Bruijn
   *index* i, with respect to the current context env. *)
let state env i =
  try
    let level = env.level - i in
    let _, _, state = IndexMap.find level env.types in
    state
  with Not_found ->
    (* TEMPORARY remove this debug information once everything works fine.
     * NB: we're currently rejecting type parameters that don't have kind ∗.
     * Reaching this code would mean that the well-kindedness check failed. *)
    IndexMap.iter (fun k (name, arity, _state) ->
      Log.debug "%d: %a[%d]" k Variable.p name arity
    ) env.types;
    Log.error "Wanted: %d, level = %d" i env.level
;;

(* [mark_duplicable env i] returns a new environment where the type parameter
 * corresponding to De Bruijn index [i] has been marked as duplicable. *)
let mark_duplicable env i =
  let n_types = IndexMap.cardinal env.types in
  let level = env.level - i in
  let arity, bitmap = env.current in
  if not (level >= n_types && level < n_types + arity) then begin
    (* This means we're trying to mark as duplicable something that's not one of
       the type parameters.
       - It can't be a globally defined data type, because [data t = T { foo:
         list; }] is not well-kinded.
       - This means that it's one of the freshly introduced binders. *)
    match IndexMap.find_opt level env.extra with
    | Some _ ->
        (* Print some meaningful error message here, saying that _ is quantified
         * somehow and that we don't have the right hypothesis. *)
        raise (NotDuplicable (TyVar i))
    | None ->
        (* If we get there then I'm seriously wrong. *)
        assert false
  end;
  let bitmap = IndexMap.add level () bitmap in
  { env with current = arity, bitmap }
;;

(* [ith_param_duplicable bitmap i] tells whether the i-th parameter of the type
 * whose bitmap is [bitmap] should be duplicable. *)
let ith_param_duplicable env bitmap i =
  (* Some fun with the De Bruijn index to find out about the global level. *)
  let level = IndexMap.cardinal env.types + i in
  Option.unit_bool (IndexMap.find_opt level bitmap)
;;

(* [bind env name] returns the new environment after we've entered an
 * extra binder whose name is [name] *)
let bind env name =
  let new_level = env.level + 1 in
  let extra = IndexMap.add new_level name env.extra in
  { env with level = new_level; extra }
;;

(* The situation is a little bit awkward, because in an environment, there's a
 * part that doesn't change: [types], a part that's threaded through all
 * computations: [current], and a part that's discarded after a recursive call:
 * [extra]. This helper function should hopefully make it easier to deal with. *)
let merge_sub_env env sub_env =
  (* Get the new bitmap from the sub-environment, because that's the part that
   * we need to thread through the computations. *)
  { env with current = sub_env.current }
;;

(* A small helper function. *)
let flatten_tyapp t =
  let rec flatten_tyapp acc = function
    | TyApp (t1, t2) ->
        flatten_tyapp (t2 :: acc) t1
    | _ as x ->
        x, List.rev acc
  in
  flatten_tyapp [] t
;;


(* ------------------------------------------------------------------------- *)

(* Some debugging / printing functions. *)

(* Give the global level of a type, get its state as a string. *)
let string_of_state env i =
  let _name, arity, state = IndexMap.find i env.types in
  let n_cons = IndexMap.cardinal env.types in
  match state with
  | Duplicable bitmap ->
      String.concat "" (Hml_List.make arity (fun i ->
        match IndexMap.find_opt (n_cons + i) bitmap with
        | Some () -> "x"
        | None -> "-")
      )
  | Exclusive ->
      "exclusive"
  | Affine ->
      "affine"
;;

(* For debugging purposes. *)
let print_env (env: env) : unit =
  IndexMap.iter (fun index (name, arity, state) ->
    Log.debug "%d: %a [%s]" index Variable.p name (string_of_state env index);
    match state with
    | Duplicable bitmap ->
        Log.debug "  keys: %s" (String.concat ","
          (List.map string_of_int (IndexMap.keys bitmap)))
    | _ ->
        ()
  ) env.types
;;

let string_of_facts (env: WellKindedness.data_type_env) facts =
  let open Bash in
  let n_cons = IndexMap.cardinal env.data_type_map in
  let string_of_fact name arity fact =
    let params = Hml_Pprint.name_gen arity in
    let all_params = String.concat " " params in
    let all_params = if List.length params > 0 then " " ^ all_params else "" in
    let print_simple w =
      Hml_String.bsprintf "%s%a%s%s is %s"
        colors.underline Variable.p name all_params colors.default w
    in
    match fact with
    | Exclusive ->
        print_simple "exclusive"
    | Affine ->
        print_simple "affine"
    | Duplicable bitmap when List.length params = 0 ->
        print_simple "duplicable"
    | Duplicable bitmap ->
        let verb = if List.length params > 1 then "are" else "is" in
        let dup_params = Hml_List.mapi (fun i param ->
          match IndexMap.find_opt (n_cons + i) bitmap with
          | Some () ->
              Some param
          | None ->
              None
        ) params in
        let dup_params = Hml_List.filter_some dup_params in
        let rec fancy_join = function
          | [] ->
              ""
          | e :: [] ->
              e
          | e1 :: e2 :: [] ->
              Printf.sprintf "%s and %s" e1 e2
          | hd :: tl ->
              Printf.sprintf "%s, %s" hd (fancy_join tl)
        in
        Hml_String.bsprintf "%s%a%s%s is duplicable if %s %s duplicable"
          colors.underline Variable.p name
          all_params colors.default (fancy_join dup_params) verb
  in
  let strings = IndexMap.fold (fun i fact acc ->
    match IndexMap.find i env.data_type_map with
    | Concrete (_flag, name, kind, _branches) ->
        let _hd, params = SurfaceSyntax.flatten_kind kind in
        let arity = List.length params in
        (string_of_fact name arity (IndexMap.find i facts)) :: acc
    | Abstract (name, _kind) ->
        Hml_String.bsprintf "%s%a%s is abstract"
          colors.underline Variable.p name
          colors.default :: acc
  ) facts [] in
  let strings = List.sort String.compare strings in
  String.concat "\n" strings
;;

(* ------------------------------------------------------------------------- *)

(* The core of the algorithm. *)

(* Perform a reverse-analysis of a type, and return an env with the [current]
 * field set to a bitmap. If bitmap index [i] is present, this means that the
 * type's parameter with *level* [i] must be marked as duplicable for the
 * original type to be duplicable itself. *)
let rev_duplicables
    (type_env: WellKindedness.data_type_env)
    (env: env)
    (t: typ) : env =
  let rec rev_duplicables (env: env) (t: typ) : env =
    match t with
    | TyUnknown
    | TyDynamic ->
        env

    | TyVar i ->
        mark_duplicable env i

    | TyFlexible _ ->
        Log.error "No flexible variable should appear at that stage."

    | TyForall ((name, kind), t)
    | TyExists ((name, kind), t) ->
        let sub_env = bind env name in
        merge_sub_env env (rev_duplicables sub_env t)

    | TyApp _ as t ->
      begin
        let hd, ts = flatten_tyapp t in
        match hd with
        | TyVar i ->
          begin
            match state env i with
            | Exclusive | Affine ->
                raise (NotDuplicable t)
            | Duplicable hd_bitmap ->
                (* For each argument of the type application, if [hd] says that
                 * its i-th argument has to be duplicable, then:
                 * - find all type variables present in the argument that have
                 * to be duplicable for the argument to be duplicable as well
                 * - and add them to the map of variables so far. *)
                Hml_List.fold_lefti (fun i env ti ->
                  if ith_param_duplicable env hd_bitmap i then
                    merge_sub_env env (rev_duplicables env ti)
                  else
                    env
                ) env ts
          end
        | _ ->
            raise (NotSupported "Sorry, we don't allow Fω yet, you can only apply types to a globally defined data type.")
      end

    | TyTuple ts ->
        List.fold_left (fun env -> function
          | TyTupleComponentValue t
          | TyTupleComponentPermission t ->
              (* For a permission to be duplicable, the underlying type has to
               * be duplicable too. *)
              merge_sub_env env (rev_duplicables env t)
        ) env ts

    | TyConcreteUnfolded (cons, fields) as t ->
      begin
        let level = DataconMap.find cons type_env.cons_map in
        match IndexMap.find level type_env.data_type_map with
        | Concrete (flag, _, _, _) ->
          begin
            match flag with
            | SurfaceSyntax.Duplicable ->
                List.fold_left (fun env -> function
                  | FieldValue (_, typ)
                  | FieldPermission typ ->
                      merge_sub_env env (rev_duplicables env typ)
                ) env fields
            | SurfaceSyntax.Exclusive ->
                raise (NotDuplicable t)
          end
        | Abstract _ ->
            assert false
      end

    (* Singleton types are always duplicable. *)
    | TySingleton _ ->
        env

    (* Arrows are always duplicable *)
    | TyArrow _ ->
        env

    | TyAnchoredPermission (x, t) ->
        (* That shouldn't be an issue, since x is probably TySingleton *)
        let env = merge_sub_env env (rev_duplicables env x) in
        (* For x: τ to be duplicable, τ has to be duplicable as well *)
        merge_sub_env env (rev_duplicables env t)
    | TyEmpty ->
        env
    | TyStar (p, q) ->
        (* For p ∗ q  to be duplicable, both p and q have to be duplicable. *)
        let env = merge_sub_env env (rev_duplicables env p) in
        merge_sub_env env (rev_duplicables env q)
  in
  rev_duplicables env t
;;

(* This creates the environment in its initial state, and transforms the
 * knowledge we have gathered on the data types into a form that's suitable
 * for our analysis. *)
let create_and_populate_env (type_env: WellKindedness.data_type_env) : env =
  let n_cons = IndexMap.cardinal type_env.data_type_map in
  let empty = {
    types = IndexMap.empty;
    current = 0, IndexMap.empty;
    extra = IndexMap.empty;
    level = n_cons;
  } in
  let env = IndexMap.fold (fun i def env ->
    match def with
    | Concrete (flag, name, kind, _branches) ->
      begin
        let _hd, kargs = SurfaceSyntax.flatten_kind kind in
        let arity = List.length kargs in
        match flag with
        | SurfaceSyntax.Exclusive ->
            { env with types =
              IndexMap.add i (name, arity, Exclusive) env.types }
        | SurfaceSyntax.Duplicable ->
            { env with types =
              IndexMap.add i (name, arity, (Duplicable IndexMap.empty)) env.types }
      end
    | Abstract (name, kind) ->
        (* In the absence of exported facts, we are conservative, and assume
         * that an abstract type is affine. Of course, later on, we might want
         * to inject here the assumptions revealed by, say, a module signature.
         * *)
        let _hd, kargs = SurfaceSyntax.flatten_kind kind in
        let arity = List.length kargs in
        { env with types =
          IndexMap.add i (name, arity, Affine) env.types }

  ) type_env.data_type_map empty in
  env
;;

let branches_for_type (data_type_env: WellKindedness.data_type_env) (level: level): data_type_def_branch list =
  let open WellKindedness in
  match LevelMap.find_opt level data_type_env.data_type_map with
  | Some (Concrete (_, _name, _kind, branches)) ->
      branches
  | Some (Abstract (name, _)) ->
      Log.error "No branches for type %a, it is abstract" Variable.p name
  | None ->
      Log.error "There is no type defined at level %d" level
;;

(* This performs one round of constraint propagation.
   - If the type is initially marked as Exclusive, it remains Exclusive.
   - If the type is marked as Duplicable, we recursively determine which ones of
   its type variables should be marked as duplicable for the whole type to be
   duplicable. *)
let one_round (type_env: WellKindedness.data_type_env) (env: env) : env =
  (* Folding on all the data types. *)
  IndexMap.fold (fun level (name, arity, state) env ->
    (* What knowledge do we have from the previous round? *)
    match state with
    | Exclusive | Affine ->
        env
    | Duplicable bitmap ->
        let branches = branches_for_type type_env level in
        (* The type is in De Bruijn, so keep track of how many binders we've
         * crossed to get inside the type. *)
        let sub_env = {
          types = env.types;
          current = arity, bitmap;
          extra = IndexMap.empty;
          level = env.level + arity;
        } in
        (* Use the knowledge acquired in the previous round to see how this
         * affects the mode of the current type mode. *)
        let new_mode =
          try
            (* Folding on the branches. *)
            let sub_env = List.fold_left (fun sub_env (_label, fields) ->
                (* Folding on the fields. *)
                List.fold_left (fun sub_env -> function
                  | FieldValue (_, typ)
                  | FieldPermission typ ->
                      (* There should be no binders left, since [extra] is for
                       * binders inside the field (e.g. for a function type). *)
                      Log.affirm
                        (IndexMap.cardinal sub_env.extra = 0)
                        "Someone didn't clean up their environment.";
                      (* This field said some variables had to be duplicable:
                        * merge in this information before moving on with
                        * [sub_env]. *)
                      merge_sub_env sub_env (rev_duplicables type_env sub_env typ)
                ) sub_env fields
              ) sub_env branches in
            Duplicable (snd sub_env.current)
          with NotDuplicable _t ->
            (* Some exception was raised: the type, although initially
             * duplicable, contains a sub-part whose type is [Exclusive] or
             * [Affine], so the whole type need to be affine. *)
            Affine
        in
        let new_state = name, arity, new_mode in
        { env with types = IndexMap.add level new_state env.types }

  ) env.types env
;;

let analyze_data_types
    (type_env: WellKindedness.data_type_env)
    : facts =
  (* In the initial environment, all the bitmaps are empty. *)
  let env = create_and_populate_env type_env in
  (* We could be even smarter and make the function return both a new env and a
   * boolean telling whether we udpated the maps or not, but that would require
   * threading some [was_modified] variable throughout all the code. Because
   * premature optimization is the root of all evil, let's leave it as is for
   * now. *)
  let rec run_to_fixpoint env =
    Bash.(Log.debug "%sOne round of fact analysis...%s" colors.blue colors.default);
    let new_env = one_round type_env env in
    Log.affirm (IndexMap.cardinal (snd env.current) = 0)
      "Someone didn't clean up their environment";
    let states_equal = fun (_, _, m1) (_, _, m2) ->
      match m1, m2 with
      | Duplicable b1, Duplicable b2 ->
          IndexMap.equal (=) b1 b2
      | Exclusive, Exclusive | Affine, Affine ->
          true
      | _ ->
          false
    in
    if IndexMap.equal states_equal new_env.types env.types then
      new_env
    else
      run_to_fixpoint new_env
  in
  let env = run_to_fixpoint env in
  (* We only want to return the facts. *)
  IndexMap.map (fun (_, _, fact) -> fact) env.types
;;