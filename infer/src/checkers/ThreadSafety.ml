(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! IStd

module F = Format
module L = Logging


module Summary = Summary.Make (struct
    type summary = ThreadSafetyDomain.summary

    let update_payload summary payload =
      { payload with Specs.threadsafety = Some summary }

    let read_from_payload payload =
      payload.Specs.threadsafety
  end)

module TransferFunctions (CFG : ProcCfg.S) = struct
  module CFG = CFG
  module Domain = ThreadSafetyDomain
  type extras = FormalMap.t

  type lock_model =
    | Lock
    | Unlock
    | NoEffect

  let get_lock_model = function
    | Procname.Java java_pname ->
        begin
          match Procname.java_get_class_name java_pname, Procname.java_get_method java_pname with
          | "java.util.concurrent.locks.Lock", "lock" ->
              Lock
          | ("java.util.concurrent.locks.ReentrantLock"
            | "java.util.concurrent.locks.ReentrantReadWriteLock$ReadLock"
            | "java.util.concurrent.locks.ReentrantReadWriteLock$WriteLock"),
            ("lock" | "tryLock" | "lockInterruptibly") ->
              Lock
          | ("java.util.concurrent.locks.Lock"
            |"java.util.concurrent.locks.ReentrantLock"
            | "java.util.concurrent.locks.ReentrantReadWriteLock$ReadLock"
            | "java.util.concurrent.locks.ReentrantReadWriteLock$WriteLock"),
            "unlock" ->
              Unlock
          | _ ->
              NoEffect
        end
    | pname when Procname.equal pname BuiltinDecl.__set_locked_attribute ->
        Lock
    | pname when Procname.equal pname BuiltinDecl.__delete_locked_attribute ->
        Unlock
    | _ ->
        NoEffect

  let resolve_id (id_map : IdAccessPathMapDomain.astate) id =
    try Some (IdAccessPathMapDomain.find id id_map)
    with Not_found -> None

  let is_constant = function
    | Exp.Const _ -> true
    | _ -> false

  let is_owned access_path owned_set =
    Domain.AccessPathSetDomain.mem access_path owned_set

  let add_path_to_state exp typ loc path_state id_map owned tenv =
    (* remove the last field of the access path, if it has any *)
    let truncate = function
      | base, []
      | base, _ :: [] -> base, []
      | base, accesses -> base, IList.rev (IList.tl (IList.rev accesses)) in

    (* we don't want to warn on writes to the field if it is (a) thread-confined, or (b) volatile *)
    let is_safe_write access_path tenv =
      let is_thread_safe_write accesses tenv = match IList.rev accesses with
        | AccessPath.FieldAccess (fieldname, Typ.Tstruct typename) :: _ ->
            begin
              match Tenv.lookup tenv typename with
              | Some struct_typ ->
                  Annotations.struct_typ_has_annot struct_typ Annotations.ia_is_thread_confined ||
                  Annotations.field_has_annot
                    fieldname struct_typ Annotations.ia_is_thread_confined ||
                  Annotations.field_has_annot fieldname struct_typ Annotations.ia_is_volatile
              | None ->
                  false
            end
        | _ ->
            false in
      is_thread_safe_write (snd access_path) tenv in
    let f_resolve_id = resolve_id id_map in

    if is_constant exp
    then
      path_state
    else
      IList.fold_left
        (fun acc rawpath ->
           if not (is_owned (truncate rawpath) owned) && not (is_safe_write rawpath tenv)
           then Domain.PathDomain.add_sink (Domain.make_access rawpath loc) acc
           else acc)
        path_state
        (AccessPath.of_exp exp typ ~f_resolve_id)

  let analyze_id_assignment lhs_id rhs_exp rhs_typ { Domain.id_map; } =
    let f_resolve_id = resolve_id id_map in
    match AccessPath.of_lhs_exp rhs_exp rhs_typ ~f_resolve_id with
    | Some rhs_access_path -> IdAccessPathMapDomain.add lhs_id rhs_access_path id_map
    | None -> id_map

  (* like PatternMatch.override_exists, but also applies [predicate] to [pname] *)
  let proc_or_override_is_annotated pname tenv predicate =
    let has_return_annot pn =
      Annotations.pname_has_return_annot
        pn
        ~attrs_of_pname:Specs.proc_resolve_attributes
        predicate in
    has_return_annot pname || PatternMatch.override_exists has_return_annot tenv pname

  let exec_instr (astate : Domain.astate) { ProcData.pdesc; tenv; extras; } _ =
    let is_allocation pn =
      Procname.equal pn BuiltinDecl.__new ||
      Procname.equal pn BuiltinDecl.__new_array in
    let is_container_write pn tenv = match pn with
      | Procname.Java java_pname ->
          let typename = Typename.Java.from_string (Procname.java_get_class_name java_pname) in
          let is_container_write_ typename _ =
            match Typename.name typename, Procname.java_get_method java_pname with
            | "java.util.List", ("add" | "addAll" | "clear" | "remove" | "set") -> true
            | "java.util.Map", ("clear" | "put" | "putAll" | "remove") -> true
            | _ -> false in
          let is_threadsafe_collection typename _ = match Typename.name typename with
            | "java.util.concurrent.ConcurrentMap" | "java.util.concurrent.CopyOnWriteArrayList" ->
                true
            | _ ->
                false in
          PatternMatch.supertype_exists tenv is_container_write_ typename &&
          not (PatternMatch.supertype_exists tenv is_threadsafe_collection typename)
      | _ -> false in
    let add_container_write pn loc exp typ (astate : Domain.astate) =
      let dummy_fieldname =
        Ident.create_fieldname (Mangled.from_string (Procname.get_method pn)) 0 in
      let dummy_access_exp = Exp.Lfield (exp, dummy_fieldname, typ) in
      let unconditional_writes =
        add_path_to_state
          dummy_access_exp
          typ
          loc
          astate.unconditional_writes
          astate.id_map
          astate.owned
          tenv in
      { astate with unconditional_writes; } in
    let is_unprotected is_locked =
      not is_locked && not (Procdesc.is_java_synchronized pdesc) in
    (* return true if the given procname boxes a primitive type into a reference type *)
    let is_box = function
      | Procname.Java java_pname ->
          begin
            match Procname.java_get_class_name java_pname, Procname.java_get_method java_pname with
            | ("java.lang.Boolean" |
               "java.lang.Byte" |
               "java.lang.Char" |
               "java.lang.Double" |
               "java.lang.Float" |
               "java.lang.Integer" |
               "java.lang.Long" |
               "java.lang.Short"),
              "valueOf" -> true
            | _ -> false
          end
      | _ ->
          false in
    let f_resolve_id = resolve_id astate.id_map in

    let open Domain in
    function
    | Sil.Call (Some (lhs_id, lhs_typ), Const (Cfun pn), _, _, _) when is_allocation pn ->
        begin
          match AccessPath.of_lhs_exp (Exp.Var lhs_id) lhs_typ ~f_resolve_id with
          | Some lhs_access_path ->
              let owned = AccessPathSetDomain.add lhs_access_path astate.owned in
              { astate with owned; }
          | None ->
              astate
        end
    | Sil.Call (ret_opt, Const (Cfun callee_pname), actuals, loc, _) ->
        let astate_callee =
          (* assuming that modeled procedures do not have useful summaries *)
          match get_lock_model callee_pname with
          | Lock ->
              { astate with locks = true; }
          | Unlock ->
              { astate with locks = false; }
          | NoEffect ->
              if is_unprotected astate.locks && is_container_write callee_pname tenv
              then
                match actuals with
                | (receiver_exp, receiver_typ) :: _ ->
                    add_container_write callee_pname loc receiver_exp receiver_typ astate
                | [] ->
                    failwithf
                      "Call to %a is marked as a container write, but has no receiver"
                      Procname.pp callee_pname
              else
                match Summary.read_summary pdesc callee_pname with
                | Some (callee_locks,
                        callee_reads,
                        callee_conditional_writes,
                        callee_unconditional_writes,
                        is_retval_owned) ->
                    let locks' = callee_locks || astate.locks in
                    let astate' =
                      (* TODO (14842325): report on constructors that aren't threadsafe
                         (e.g., constructors that access static fields) *)
                      if is_unprotected locks'
                      then
                        let call_site = CallSite.make callee_pname loc in
                        (* add the conditional writes rooted in the callee formal at [index] to
                           the current state *)
                        let add_conditional_writes
                            ((cond_writes, uncond_writes) as acc) index (actual_exp, actual_typ) =
                          if is_constant actual_exp
                          then
                            acc
                          else
                            try
                              let callee_cond_writes_for_index' =
                                let callee_cond_writes_for_index =
                                  ConditionalWritesDomain.find index callee_conditional_writes in
                                PathDomain.with_callsite callee_cond_writes_for_index call_site in
                              begin
                                match AccessPath.of_lhs_exp actual_exp actual_typ ~f_resolve_id with
                                | Some actual_access_path ->
                                    if is_owned actual_access_path astate.owned
                                    then
                                      (* the actual passed to the current callee is owned. drop all
                                         the conditional writes for that actual, since they're all
                                         safe *)
                                      acc
                                    else
                                      let base = fst actual_access_path in
                                      begin
                                        match FormalMap.get_formal_index base extras with
                                        | Some formal_index ->
                                            (* the actual passed to the current callee is rooted in
                                               a formal. add to conditional writes *)
                                            let conditional_writes' =
                                              try
                                                ConditionalWritesDomain.find
                                                  formal_index cond_writes
                                                |> PathDomain.join callee_cond_writes_for_index'
                                              with Not_found ->
                                                callee_cond_writes_for_index' in
                                            let cond_writes' =
                                              ConditionalWritesDomain.add
                                                formal_index conditional_writes' cond_writes in
                                            cond_writes', uncond_writes
                                        | None ->
                                            (* access path not owned and not rooted in a formal. add
                                               to unconditional writes *)
                                            cond_writes,
                                            PathDomain.join
                                              uncond_writes callee_cond_writes_for_index'
                                      end
                                | _ ->
                                    cond_writes,
                                    PathDomain.join uncond_writes callee_cond_writes_for_index'
                              end
                            with Not_found ->
                              acc in
                        let conditional_writes, unconditional_writes =
                          let combined_unconditional_writes =
                            PathDomain.with_callsite callee_unconditional_writes call_site
                            |> PathDomain.join astate.unconditional_writes in
                          IList.fold_lefti
                            add_conditional_writes
                            (astate.conditional_writes, combined_unconditional_writes)
                            actuals in
                        let reads =
                          PathDomain.with_callsite callee_reads call_site
                          |> PathDomain.join astate.reads in
                        { astate with reads; conditional_writes; unconditional_writes; }
                      else
                        astate in
                    let owned = match ret_opt with
                      | Some (ret_id, ret_typ) when is_retval_owned ->
                          AccessPathSetDomain.add (AccessPath.of_id ret_id ret_typ) astate'.owned
                      | _ ->
                          astate'.owned in
                    { astate' with locks = locks'; owned; }
                | None ->
                    if is_box callee_pname
                    then
                      match ret_opt, actuals with
                      | Some (ret_id, ret_typ), (actual_exp, actual_typ) :: _ ->
                          begin
                            match AccessPath.of_lhs_exp actual_exp actual_typ ~f_resolve_id with
                            | Some ap when AccessPathSetDomain.mem ap astate.functional ->
                                let functional =
                                  AccessPathSetDomain.add
                                    (AccessPath.of_id ret_id ret_typ) astate.functional in
                                { astate with functional; }
                            | _ ->
                                astate
                          end
                      | _ ->
                          astate
                    else
                      astate in
        begin
          match ret_opt with
          | Some (_, (Typ.Tint ILong | Tfloat FDouble)) ->
              (* writes to longs and doubles are not guaranteed to be atomic in Java, so don't
                 bother tracking whether a returned long or float value is functional *)
              astate_callee
          | Some (ret_id, ret_typ) when
              proc_or_override_is_annotated callee_pname tenv Annotations.ia_is_functional ->
              let functional =
                AccessPathSetDomain.add
                  (AccessPath.of_id ret_id ret_typ) astate_callee.functional in
              { astate_callee with functional; }
          | _ ->
              astate_callee
        end

    | Sil.Store (Exp.Lvar lhs_pvar, lhs_typ, rhs_exp, _) when Pvar.is_frontend_tmp lhs_pvar ->
        let id_map' = analyze_id_assignment (Var.of_pvar lhs_pvar) rhs_exp lhs_typ astate in
        { astate with id_map = id_map'; }

    | Sil.Store (lhs_exp, lhs_typ, rhs_exp, loc) ->
        let get_formal_index exp typ = match AccessPath.of_lhs_exp exp typ ~f_resolve_id with
          | Some (base, _) -> FormalMap.get_formal_index base extras
          | None -> None in
        let is_marked_functional exp typ functional_set =
          match AccessPath.of_lhs_exp exp typ ~f_resolve_id with
          | Some access_path -> AccessPathSetDomain.mem access_path functional_set
          | None -> false in
        let conditional_writes, unconditional_writes =
          match lhs_exp with
          | Lfield (base_exp, _, typ)
            when is_unprotected astate.locks (* abstracts no lock being held *) &&
                 not (is_marked_functional rhs_exp lhs_typ astate.functional) ->
              begin
                match get_formal_index base_exp typ with
                | Some formal_index ->
                    let conditional_writes_for_index =
                      try ConditionalWritesDomain.find formal_index astate.conditional_writes
                      with Not_found -> PathDomain.empty in
                    let conditional_writes_for_index' =
                      add_path_to_state
                        lhs_exp
                        typ
                        loc
                        conditional_writes_for_index
                        astate.id_map
                        astate.owned
                        tenv in
                    ConditionalWritesDomain.add
                      formal_index conditional_writes_for_index' astate.conditional_writes,
                    astate.unconditional_writes
                | None ->
                    astate.conditional_writes,
                    add_path_to_state
                      lhs_exp
                      typ
                      loc
                      astate.unconditional_writes
                      astate.id_map
                      astate.owned
                      tenv
              end
          | _ ->
              astate.conditional_writes, astate.unconditional_writes in

        (* if rhs is owned/functional, propagate to lhs. otherwise, remove lhs from
           ownership/functional set (since it may have previously held an owned/functional memory
           loc and is now being reassigned *)
        let lhs_access_path_opt = AccessPath.of_lhs_exp lhs_exp lhs_typ ~f_resolve_id in
        let rhs_access_path_opt = AccessPath.of_lhs_exp rhs_exp lhs_typ ~f_resolve_id in
        let update_access_path_set access_path_set =
          match lhs_access_path_opt, rhs_access_path_opt with
          | Some lhs_access_path, Some rhs_access_path ->
              if AccessPathSetDomain.mem rhs_access_path access_path_set
              then AccessPathSetDomain.add lhs_access_path access_path_set
              else AccessPathSetDomain.remove lhs_access_path access_path_set
          | Some lhs_access_path, None ->
              if is_constant rhs_exp
              then AccessPathSetDomain.add lhs_access_path access_path_set
              else AccessPathSetDomain.remove lhs_access_path access_path_set
          | _ ->
              access_path_set in
        let owned = update_access_path_set astate.owned in
        let functional = update_access_path_set astate.functional in
        { astate with conditional_writes; unconditional_writes; owned; functional; }

    | Sil.Load (lhs_id, rhs_exp, rhs_typ, loc) ->
        let id_map = analyze_id_assignment (Var.of_id lhs_id) rhs_exp rhs_typ astate in
        let reads =
          match rhs_exp with
          | Lfield ( _, _, typ) when is_unprotected astate.locks ->
              add_path_to_state rhs_exp typ loc astate.reads astate.id_map astate.owned tenv
          | _ ->
              astate.reads in

        (* if rhs is owned/functional, propagate to lhs *)
        let owned, functional =
          match AccessPath.of_lhs_exp rhs_exp rhs_typ ~f_resolve_id with
          | Some rhs_access_path ->
              let propagate_to_lhs access_path_set =
                if AccessPathSetDomain.mem rhs_access_path access_path_set
                then AccessPathSetDomain.add (AccessPath.of_id lhs_id rhs_typ) access_path_set
                else access_path_set in
              propagate_to_lhs astate.owned, propagate_to_lhs astate.functional
          | _ ->
              if is_constant rhs_exp
              then
                AccessPathSetDomain.add (AccessPath.of_id lhs_id rhs_typ) astate.owned,
                astate.functional
              else
                astate.owned, astate.functional in
        { astate with Domain.reads; id_map; owned; functional; }

    | Sil.Remove_temps (ids, _) ->
        let id_map =
          IList.fold_left
            (fun acc id -> IdAccessPathMapDomain.remove (Var.of_id id) acc)
            astate.id_map
            ids in
        { astate with id_map; }

    |  _  ->
        astate
end

module Analyzer = AbstractInterpreter.Make (ProcCfg.Normal) (TransferFunctions)

module Interprocedural = AbstractInterpreter.Interprocedural (Summary)

(* a results table is a Map where a key is an a procedure environment,
   i.e., something of type Idenv.t * Tenv.t * Procname.t * Procdesc.t
*)
module ResultsTableType = Caml.Map.Make (struct
    type t = Idenv.t * Tenv.t * Procname.t * Procdesc.t
    let compare (_, _, pn1, _) (_,_,pn2,_) =  Procname.compare pn1 pn2
  end)

(* we want to consider Builder classes and other safe immutablility-ensuring patterns as
   thread-safe. we are overly friendly about this for now; any class whose name ends with `Builder`
   is assumed to be thread-safe. in the future, we can ask for builder classes to be annotated with
   @Builder and verify that annotated classes satisfy the expected invariants. *)
let is_builder_class class_name =
  String.is_suffix ~suffix:"Builder" class_name

(* similarly, we assume that immutable classes safely encapsulate their state *)
let is_immutable_collection_class class_name tenv =
  let immutable_collections = [
    "com.google.common.collect.ImmutableCollection";
    "com.google.common.collect.ImmutableMap";
    "com.google.common.collect.ImmutableTable";
  ] in
  PatternMatch.supertype_exists
    tenv
    (fun typename _ ->
       List.mem ~equal:String.equal immutable_collections (Typename.name typename))
    class_name

let is_call_to_builder_class_method = function
  | Procname.Java java_pname -> is_builder_class (Procname.java_get_class_name java_pname)
  | _ -> false

let is_call_to_immutable_collection_method tenv = function
  | Procname.Java java_pname ->
      is_immutable_collection_class (Procname.java_get_class_type_name java_pname) tenv
  | _ ->
      false

(* Methods in @ThreadConfined classes and methods annotated with @ThreadConfied are assumed to all
   run on the same thread. For the moment we won't warn on accesses resulting from use of such
   methods at all. In future we should account for races between these methods and methods from
   completely different classes that don't necessarily run on the same thread as the confined
   object. *)
let is_thread_confined_method tenv pdesc =
  Annotations.pdesc_return_annot_ends_with pdesc Annotations.thread_confined ||
  PatternMatch.check_current_class_attributes
    Annotations.ia_is_thread_confined tenv (Procdesc.get_proc_name pdesc)

(* we don't want to warn on methods that run on the UI thread because they should always be
   single-threaded *)
let runs_on_ui_thread proc_desc =
  (* assume that methods annotated with @UiThread, @OnEvent, @OnBind, @OnMount, @OnUnbind,
     @OnUnmount always run on the UI thread *)
  Annotations.pdesc_has_return_annot
    proc_desc
    (fun annot -> Annotations.ia_is_ui_thread annot ||
                  Annotations.ia_is_on_bind annot ||
                  Annotations.ia_is_on_event annot ||
                  Annotations.ia_is_on_mount annot ||
                  Annotations.ia_is_on_unbind annot ||
                  Annotations.ia_is_on_unmount annot)

let is_assumed_thread_safe pdesc =
  Annotations.pdesc_return_annot_ends_with pdesc Annotations.assume_thread_safe

(* return true if we should compute a summary for the procedure. if this returns false, we won't
   analyze the procedure or report any warnings on it *)
(* note: in the future, we will want to analyze the procedures in all of these cases in order to
   find more bugs. this is just a temporary measure to avoid obvious false positives *)
let should_analyze_proc pdesc tenv =
  let pn = Procdesc.get_proc_name pdesc in
  not (Procname.is_class_initializer pn) &&
  not (FbThreadSafety.is_logging_method pn) &&
  not (is_call_to_builder_class_method pn) &&
  not (is_call_to_immutable_collection_method tenv pn) &&
  not (runs_on_ui_thread pdesc) &&
  not (is_thread_confined_method tenv pdesc) &&
  not (is_assumed_thread_safe pdesc)

(* return true if we should report on unprotected accesses during the procedure *)
let should_report_on_proc (_, _, proc_name, proc_desc) =
  not (Procname.java_is_autogen_method proc_name) &&
  Procdesc.get_access proc_desc <> PredSymb.Private &&
  not (Annotations.pdesc_return_annot_ends_with proc_desc Annotations.visibleForTesting)

(* creates a map from proc_envs to postconditions *)
let make_results_table get_proc_desc file_env =
  (* make a Map sending each element e of list l to (f e) *)
  let map_post_computation_over_procs f l =
    IList.fold_left (fun m p -> ResultsTableType.add p (f p) m
                    ) ResultsTableType.empty l
  in
  let is_initializer tenv proc_name =
    Procname.is_constructor proc_name || FbThreadSafety.is_custom_init tenv proc_name in
  let compute_post_for_procedure = (* takes proc_env as arg *)
    fun (idenv, tenv, proc_name, proc_desc) ->
      let open ThreadSafetyDomain in
      let has_lock = false in
      let ret_is_owned = false in
      let empty =
        has_lock, PathDomain.empty, ConditionalWritesDomain.empty, PathDomain.empty, ret_is_owned in
      (* convert the abstract state to a summary by dropping the id map *)
      let compute_post ({ ProcData.pdesc; tenv; extras; } as proc_data) =
        if should_analyze_proc pdesc tenv
        then
          begin
            if not (Procdesc.did_preanalysis pdesc) then Preanal.do_liveness pdesc tenv;
            let initial =
              if is_initializer tenv (Procdesc.get_proc_name pdesc)
              then
                (* express that the constructor owns [this] *)
                match FormalMap.get_formal_base 0 extras with
                | Some base ->
                    let owned = ThreadSafetyDomain.AccessPathSetDomain.singleton (base, []) in
                    { ThreadSafetyDomain.empty with owned; }
                | None -> ThreadSafetyDomain.empty
              else
                ThreadSafetyDomain.empty in
            match Analyzer.compute_post proc_data ~initial with
            | Some { locks; reads; conditional_writes; unconditional_writes; owned; } ->
                let return_var_ap =
                  AccessPath.of_pvar
                    (Pvar.get_ret_pvar (Procdesc.get_proc_name pdesc))
                    (Procdesc.get_ret_type pdesc) in
                let return_is_owned = AccessPathSetDomain.mem return_var_ap owned in
                Some (locks, reads, conditional_writes, unconditional_writes, return_is_owned)
            | None ->
                None
          end
        else
          Some empty in
      let callback_arg =
        let get_procs_in_file _ = [] in
        { Callbacks.get_proc_desc; get_procs_in_file; idenv; tenv; proc_name; proc_desc } in
      match
        Interprocedural.compute_and_store_post
          ~compute_post
          ~make_extras:FormalMap.make
          callback_arg with
      | Some post -> post
      | None -> empty
  in
  map_post_computation_over_procs compute_post_for_procedure file_env

let get_current_class_and_threadsafe_superclasses tenv pname =
  match pname with
  | Procname.Java java_pname ->
      let current_class = Procname.java_get_class_type_name java_pname in
      let thread_safe_annotated_classes = PatternMatch.find_superclasses_with_attributes
          Annotations.ia_is_thread_safe tenv current_class
      in
      Some (current_class,thread_safe_annotated_classes)
  | _ -> None  (*shouldn't happen*)

(** The addendum message says that a superclass is marked @ThreadSafe,
    when the current class is not so marked*)
let calculate_addendum_message tenv pname =
  match get_current_class_and_threadsafe_superclasses tenv pname with
  | Some (current_class,thread_safe_annotated_classes) ->
      if not (List.mem ~equal:Typename.equal thread_safe_annotated_classes current_class) then
        match thread_safe_annotated_classes with
        | hd::_ -> F.asprintf "\n Note: Superclass %a is marked @ThreadSafe." Typename.pp hd
        | [] -> ""
      else ""
  | _ -> ""

let combine_conditional_unconditional_writes conditional_writes unconditional_writes =
  let open ThreadSafetyDomain in
  ConditionalWritesDomain.fold
    (fun _ writes acc -> PathDomain.join writes acc)
    conditional_writes
    unconditional_writes

let report_thread_safety_violations ( _, tenv, pname, pdesc) trace =
  let open ThreadSafetyDomain in
  let trace_of_pname callee_pname =
    match Summary.read_summary pdesc callee_pname with
    | Some (_, _, conditional_writes, unconditional_writes, _) ->
        combine_conditional_unconditional_writes conditional_writes unconditional_writes
    | _ ->
        PathDomain.empty in
  let report_one_path ((_, sinks) as path) =
    let pp_accesses fmt sink =
      let _, accesses = PathDomain.Sink.kind sink in
      AccessPath.pp_access_list fmt accesses in
    let initial_sink, _ = IList.hd (IList.rev sinks) in
    let final_sink, _ = IList.hd sinks in
    let initial_sink_site = PathDomain.Sink.call_site initial_sink in
    let final_sink_site = PathDomain.Sink.call_site final_sink in
    let desc_of_sink sink =
      if CallSite.equal (PathDomain.Sink.call_site sink) final_sink_site
      then
        Format.asprintf "access to %a" pp_accesses sink
      else
        Format.asprintf
          "call to %a" Procname.pp (CallSite.pname (PathDomain.Sink.call_site sink)) in
    let loc = CallSite.loc (PathDomain.Sink.call_site initial_sink) in
    let ltr = PathDomain.to_sink_loc_trace ~desc_of_sink path in
    let msg = Localise.to_string Localise.thread_safety_violation in
    let description =
      Format.asprintf "Public method %a%s writes to field %a outside of synchronization.%s"
        Procname.pp pname
        (if CallSite.equal final_sink_site initial_sink_site then "" else " indirectly")
        pp_accesses final_sink
        (calculate_addendum_message tenv pname) in
    let exn = Exceptions.Checkers (msg, Localise.verbatim_desc description) in
    Reporting.log_error pname ~loc ~ltr exn in

  IList.iter
    report_one_path
    (PathDomain.get_reportable_sink_paths trace ~trace_of_pname)

(* Currently we analyze if there is an @ThreadSafe annotation on at least one of
   the classes in a file. This might be tightened in future or even broadened in future
   based on other criteria *)
let should_report_on_file file_env =
  let current_class_or_super_marked_threadsafe =
    fun (_, tenv, pname, _) ->
      match get_current_class_and_threadsafe_superclasses tenv pname with
      | Some (_, thread_safe_annotated_classes) ->
          not (List.is_empty thread_safe_annotated_classes)
      | _ -> false
  in
  let current_class_marked_not_threadsafe =
    fun (_, tenv, pname, _) ->
      PatternMatch.check_current_class_attributes Annotations.ia_is_not_thread_safe tenv pname
  in
  not (List.exists ~f:current_class_marked_not_threadsafe file_env) &&
  List.exists ~f:current_class_or_super_marked_threadsafe file_env

(* For now, just checks if there is one active element amongst the posts of the analyzed methods.
   This indicates that the method races with itself. To be refined later. *)
let process_results_table file_env tab =
  let should_report_on_all_procs = should_report_on_file file_env in
  (* TODO (t15588153): clean this up *)
  let is_thread_safe_method pdesc tenv =
    let overrides_thread_safe_method pname tenv =
      PatternMatch.override_exists
        (fun pn ->
           Annotations.pname_has_return_annot
             pn
             ~attrs_of_pname:Specs.proc_resolve_attributes
             Annotations.ia_is_thread_safe_method)
        tenv pname in
    Annotations.pdesc_return_annot_ends_with pdesc Annotations.thread_safe_method ||
    overrides_thread_safe_method (Procdesc.get_proc_name pdesc) tenv in
  let should_report ((_, tenv, _, pdesc) as proc_env) =
    (should_report_on_all_procs || is_thread_safe_method pdesc tenv)
    && should_report_on_proc proc_env in
  ResultsTableType.iter (* report errors for each method *)
    (fun proc_env (_, _, conditional_writes, unconditional_writes, _) ->
       if should_report proc_env then
         combine_conditional_unconditional_writes conditional_writes unconditional_writes
         |> report_thread_safety_violations proc_env)
    tab

(*This is a "cluster checker" *)
(*Gathers results by analyzing all the methods in a file, then post-processes
  the results to check (approximation of) thread safety *)
(* file_env: (Idenv.t * Tenv.t * Procname.t * Procdesc.t) list *)
let file_analysis _ _ get_procdesc file_env =
  process_results_table file_env (make_results_table get_procdesc file_env)
