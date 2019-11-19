(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

type violation = {is_strict_mode: bool; lhs: Nullability.t; rhs: Nullability.t} [@@deriving compare]

type assignment_type =
  | PassingParamToFunction of
      { param_signature: AnnotatedSignature.param_signature
      ; model_source: AnnotatedSignature.model_source option
      ; actual_param_expression: string
      ; param_position: int
      ; function_procname: Typ.Procname.t }
  | AssigningToField of Typ.Fieldname.t
  | ReturningFromFunction of Typ.Procname.t
[@@deriving compare]

let is_whitelisted_assignment ~is_strict_mode ~lhs ~rhs =
  match (is_strict_mode, lhs, rhs) with
  | false, Nullability.Nonnull, Nullability.DeclaredNonnull ->
      (* We allow DeclaredNonnull -> Nonnull conversion outside of strict mode for better adoption.
         Otherwise using strictified classes in non-strict context becomes a pain because
         of extra warnings.
      *)
      true
  | _ ->
      false


let check ~is_strict_mode ~lhs ~rhs =
  let is_allowed_assignment =
    Nullability.is_subtype ~subtype:rhs ~supertype:lhs
    || is_whitelisted_assignment ~is_strict_mode ~lhs ~rhs
  in
  Result.ok_if_true is_allowed_assignment ~error:{is_strict_mode; lhs; rhs}


let get_origin_opt assignment_type origin =
  let should_show_origin =
    match assignment_type with
    | PassingParamToFunction {actual_param_expression} ->
        not
          (ErrorRenderingUtils.is_object_nullability_self_explanatory
             ~object_expression:actual_param_expression origin)
    | AssigningToField _ | ReturningFromFunction _ ->
        true
  in
  if should_show_origin then Some origin else None


let pp_param_name fmt mangled =
  let name = Mangled.to_string mangled in
  if String.is_substring name ~substring:"_arg_" then
    (* The real name was not fetched for whatever reason, this is an autogenerated name *)
    Format.fprintf fmt ""
  else Format.fprintf fmt "(%a)" MarkupFormatter.pp_monospaced name


let violation_description _ assignment_type ~rhs_origin =
  let suffix =
    get_origin_opt assignment_type rhs_origin
    |> Option.bind ~f:(fun origin -> TypeOrigin.get_description origin)
    |> Option.value_map ~f:(fun origin -> ": " ^ origin) ~default:"."
  in
  let module MF = MarkupFormatter in
  match assignment_type with
  | PassingParamToFunction
      {model_source; param_signature; actual_param_expression; param_position; function_procname} ->
      let argument_description =
        if String.equal "null" actual_param_expression then "is `null`"
        else Format.asprintf "%a is nullable" MF.pp_monospaced actual_param_expression
      in
      let nullability_evidence =
        match model_source with
        | None ->
            ""
        | Some InternalModel ->
            " (according to nullsafe internal models)"
        | Some (ThirdPartyRepo {filename; line_number}) ->
            Format.sprintf " (see %s at line %d)"
              (ThirdPartyAnnotationGlobalRepo.get_user_friendly_third_party_sig_file_name ~filename)
              line_number
      in
      Format.asprintf "%a: parameter #%d%a is declared non-nullable%s but the argument %s%s"
        MF.pp_monospaced
        (Typ.Procname.to_simplified_string ~withclass:true function_procname)
        param_position pp_param_name param_signature.mangled nullability_evidence
        argument_description suffix
  | AssigningToField field_name ->
      Format.asprintf "%a is declared non-nullable but is assigned a nullable%s" MF.pp_monospaced
        (Typ.Fieldname.to_flat_string field_name)
        suffix
  | ReturningFromFunction function_proc_name ->
      Format.asprintf
        "%a: return type is declared non-nullable but the method returns a nullable value%s"
        MF.pp_monospaced
        (Typ.Procname.to_simplified_string ~withclass:false function_proc_name)
        suffix
