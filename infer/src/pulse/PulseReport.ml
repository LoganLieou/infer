(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging
open PulseBasicInterface
open PulseDomainInterface

let report ~latent proc_desc err_log diagnostic =
  let open Diagnostic in
  Reporting.log_issue proc_desc err_log ~loc:(get_location diagnostic) ~ltr:(get_trace diagnostic)
    Pulse
    (get_issue_type ~latent diagnostic)
    (get_message diagnostic)


let report_latent_issue proc_desc err_log latent_issue =
  LatentIssue.to_diagnostic latent_issue |> report ~latent:true proc_desc err_log


(* skip reporting on Java classes annotated with [@Nullsafe] if requested *)
let is_nullsafe_error tenv diagnostic jn =
  (not Config.pulse_nullsafe_report_npe)
  && IssueType.equal
       (Diagnostic.get_issue_type ~latent:false diagnostic)
       (IssueType.nullptr_dereference ~latent:false)
  && match NullsafeMode.of_java_procname tenv jn with Default -> false | Local _ | Strict -> true


(* skip reporting for constant dereference (eg null dereference) if the source of the null value is
   not on the path of the access, otherwise the report will probably be too confusing: the actual
   source of the null value can be obscured as any value equal to 0 (or the constant) can be
   selected as the candidate for the trace, even if it has nothing to do with the error besides
   being equal to the value being dereferenced *)
let is_constant_deref_without_invalidation (diagnostic : Diagnostic.t) =
  match diagnostic with
  | MemoryLeak _
  | ResourceLeak _
  | ErlangError _
  | ReadUninitializedValue _
  | StackVariableAddressEscape _
  | UnnecessaryCopy _ ->
      false
  | AccessToInvalidAddress {invalidation; access_trace} -> (
    match invalidation with
    | ConstantDereference _ ->
        not (Trace.has_invalidation access_trace)
    | CFree
    | CustomFree _
    | CppDelete
    | CppDeleteArray
    | EndIterator
    | GoneOutOfScope _
    | OptionalEmpty
    | StdVector _
    | JavaIterator _ ->
        false )


let is_suppressed tenv proc_desc diagnostic astate =
  if is_constant_deref_without_invalidation diagnostic then (
    L.d_printfln ~color:Red
      "Dropping error: constant dereference with no invalidation in the access trace" ;
    true )
  else
    match Procdesc.get_proc_name proc_desc with
    | Procname.Java jn ->
        is_nullsafe_error tenv diagnostic jn
        || not (AbductiveDomain.skipped_calls_match_pattern astate)
    | _ ->
        false


let summary_of_error_post tenv proc_desc location mk_error astate =
  match AbductiveDomain.summary_of_post tenv proc_desc location astate with
  | Sat (Ok astate)
  | Sat (Error (`MemoryLeak (astate, _, _, _)) | Error (`ResourceLeak (astate, _, _, _))) ->
      (* ignore potential memory leaks: error'ing in the middle of a function will typically produce
         spurious leaks *)
      Sat (mk_error astate)
  | Sat (Error (`PotentialInvalidAccessSummary (summary, addr, trace))) ->
      (* ignore the error we wanted to report (with [mk_error]): the abstract state contained a
         potential error already so report [error] instead *)
      Sat (AccessResult.of_abductive_error (`PotentialInvalidAccessSummary (summary, addr, trace)))
  | Unsat ->
      Unsat


let summary_error_of_error tenv proc_desc location (error : AbductiveDomain.t AccessResult.error) :
    AbductiveDomain.summary AccessResult.error SatUnsat.t =
  match error with
  | PotentialInvalidAccessSummary {astate; address; must_be_valid} ->
      Sat (PotentialInvalidAccessSummary {astate; address; must_be_valid})
  | PotentialInvalidAccess {astate; address; must_be_valid} ->
      summary_of_error_post tenv proc_desc location
        (fun astate -> PotentialInvalidAccess {astate; address; must_be_valid})
        astate
  | ReportableError {astate; diagnostic} ->
      summary_of_error_post tenv proc_desc location
        (fun astate -> ReportableError {astate; diagnostic})
        astate
  | ReportableErrorSummary {astate; diagnostic} ->
      Sat (ReportableErrorSummary {astate; diagnostic})
  | ISLError astate ->
      summary_of_error_post tenv proc_desc location (fun astate -> ISLError astate) astate


let report_summary_error tenv proc_desc err_log
    (access_error : AbductiveDomain.summary AccessResult.error) : ExecutionDomain.summary option =
  match access_error with
  | PotentialInvalidAccess {astate; address; must_be_valid}
  | PotentialInvalidAccessSummary {astate; address; must_be_valid} ->
      if Config.pulse_report_latent_issues then
        report ~latent:true proc_desc err_log
          (AccessToInvalidAddress
             { calling_context= []
             ; invalidation= ConstantDereference IntLit.zero
             ; invalidation_trace= Immediate {location= Procdesc.get_loc proc_desc; history= Epoch}
             ; access_trace= fst must_be_valid
             ; must_be_valid_reason= snd must_be_valid } ) ;
      Some (LatentInvalidAccess {astate; address; must_be_valid; calling_context= []})
  | ISLError astate ->
      Some (ISLLatentMemoryError astate)
  | ReportableError {astate; diagnostic} | ReportableErrorSummary {astate; diagnostic} -> (
    match LatentIssue.should_report astate diagnostic with
    | `ReportNow ->
        if is_suppressed tenv proc_desc diagnostic astate then L.d_printfln "suppressed error"
        else report ~latent:false proc_desc err_log diagnostic ;
        if Diagnostic.aborts_execution diagnostic then Some (AbortProgram astate) else None
    | `DelayReport latent_issue ->
        if Config.pulse_report_latent_issues then report_latent_issue proc_desc err_log latent_issue ;
        Some (LatentAbortProgram {astate; latent_issue}) )


let report_error tenv proc_desc err_log location
    (access_error : AbductiveDomain.t AccessResult.error) =
  let open SatUnsat.Import in
  summary_error_of_error tenv proc_desc location access_error
  >>| report_summary_error tenv proc_desc err_log


let report_errors tenv proc_desc err_log location errors =
  let open SatUnsat.Import in
  List.rev errors
  |> List.fold ~init:(Sat None) ~f:(fun sat_result error ->
         match sat_result with
         | Unsat | Sat (Some _) ->
             sat_result
         | Sat None ->
             report_error tenv proc_desc err_log location error )


let report_exec_results tenv proc_desc err_log location results =
  List.filter_map results ~f:(fun exec_result ->
      match PulseResult.to_result exec_result with
      | Ok post ->
          Some post
      | Error errors -> (
        match report_errors tenv proc_desc err_log location errors with
        | Unsat ->
            None
        | Sat None -> (
          match exec_result with
          | Ok _ | FatalError _ ->
              L.die InternalError
                "report_errors returned None but the result was not a recoverable error"
          | Recoverable (exec_state, _) ->
              Some exec_state )
        | Sat (Some exec_state) ->
            Some (exec_state :> ExecutionDomain.t) ) )


let report_results tenv proc_desc err_log location results =
  let open PulseResult.Let_syntax in
  List.map results ~f:(fun result ->
      let+ astate = result in
      ExecutionDomain.ContinueProgram astate )
  |> report_exec_results tenv proc_desc err_log location


let report_result tenv proc_desc err_log location result =
  report_results tenv proc_desc err_log location [result]
