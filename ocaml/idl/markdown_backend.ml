(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Printf

open Datamodel_types
open Datamodel
open Datamodel_utils
open Dm_api

open Stdext
open Xstringext
open Pervasiveext

(*column widths for the autogenerated tables*)
let col_width_15 = 15
let col_width_20 = 20
let col_width_30 = 30
let col_width_40 = 40
let col_width_70 = 70

let pad_right x max_width =
  let length = String.length x in
  if String.length x < max_width then x ^ String.make (max_width - length) ' '
  else x

let compare_case_ins x y =
  compare (String.lowercase_ascii x) (String.lowercase_ascii y)

let escape s =
  let sl = String.explode s in
  let esc_char =
    function
    | '\\' -> "&#92;"
    | '*' -> "&#42;"
    | '_' -> "&#95;"
    | '{' -> "&#123;"
    | '}' -> "&#125;"
    | '[' -> "&#91;"
    | ']' -> "&#93;"
    | '(' -> "&#40;"
    | ')' -> "&#41;"
    | '>' -> "&gt;"
    | '<' -> "&lt;"
    | '#' -> "&#35;"
    | '+' -> "&#43;"
    | '-' -> "&#45;"
    | '!' -> "&#33;"
    | c -> String.make 1 c in
  let escaped_list = List.map esc_char sl in
  String.concat "" escaped_list

let is_prim_type = function
  | String | Int | Float | Bool | DateTime -> true
  | _ -> false

let is_prim_opt_type = function
  | None -> true
  | Some (ty,_) -> is_prim_type ty

let rec of_ty_verbatim = function
  | String -> "string"
  | Int -> "int"
  | Float -> "float"
  | Bool -> "bool"
  | DateTime -> "datetime"
  | Enum (name, things) -> name
  | Set x -> sprintf "%s set" (of_ty_verbatim x)
  | Map (a, b) -> sprintf "(%s -> %s) map" (of_ty_verbatim a) (of_ty_verbatim b)
  | Ref obj -> obj ^ " ref"
  | Record obj -> obj ^ " record"


let rec of_ty = function
  | String -> "string"
  | Int -> "int"
  | Float -> "float"
  | Bool -> "bool"
  | DateTime -> "datetime"
  | Enum (name, things) -> escape name
  | Set x -> (of_ty x) ^ " set"
  | Map (a, b) -> "(" ^ (of_ty a) ^ " &#45;&gt; " ^ (of_ty b) ^ ") map"
  | Ref obj -> (escape obj) ^ " ref"
  | Record obj -> (escape obj) ^ " record"

let of_ty_opt = function
    None -> "void" | Some(ty, _) -> of_ty ty

let of_ty_opt_verbatim = function
    None -> "void" | Some(ty, _) -> of_ty_verbatim ty

let desc_of_ty_opt = function
    None -> "" | Some(_, desc) -> desc

let string_of_qualifier = function
  | StaticRO   -> "_RO/constructor_"
  | DynamicRO  -> "_RO/runtime_"
  | RW         -> "_RW_"


let is_removal_marker x =
  match x with | (Removed,_,_) -> true | _ -> false

let is_deprecation_marker x =
  match x with | (Deprecated,_,_) -> true | _ -> false

(* Make a markdown section for an API-specified message *)
let markdown_section_of_message printer ~is_class_deprecated ~is_class_removed x =
  let return_type = of_ty_opt_verbatim x.msg_result in

  printer (sprintf "#### RPC name: %s" (escape x.msg_name));
  printer "";
  if List.exists is_removal_marker x.msg_lifecycle || is_class_removed then
  begin
    printer "**This message is removed.**";
    printer ""
  end
  else if List.exists is_deprecation_marker x.msg_lifecycle || is_class_deprecated then
  begin
    printer "**This message is deprecated.**";
    printer ""
  end;
  printer "_Overview:_";
  printer "";
  printer (escape x.msg_doc);
  printer "";
  printer "_Signature:_";
  printer "";
  printer "```";
  printer (sprintf "%s %s (%s)"
    (of_ty_opt_verbatim x.msg_result) x.msg_name
    (String.concat ", "
      ((if x.msg_session then ["session ref session_id"] else []) @
        (List.map (fun p -> of_ty_verbatim p.param_type ^ " " ^ p.param_name) x.msg_params)))
  );
  printer "```";

  if x.msg_params <> [] then begin
    printer "_Arguments:_";
    printer "";
    printer "|type                          |name                          |description                             |";
    printer "|:-----------------------------|:-----------------------------|:---------------------------------------|";
    if x.msg_session then
        printer "|session ref                   |session_id                    |Reference to a valid session            |";

    let get_param_row p = sprintf "|`%s`|%s|%s|"
      (pad_right (of_ty_verbatim p.param_type) (col_width_30 - 2))
      (pad_right (escape p.param_name) col_width_30)
      (pad_right (escape p.param_doc) col_width_40)
    in
    List.iter (fun p -> printer (get_param_row p)) x.msg_params;
    printer "";

    printer (sprintf "_Return Type:_ `%s`" return_type);
    printer "";
    let descr= desc_of_ty_opt x.msg_result in
    if descr <> ""  then
      (printer (escape descr);
      printer "")
  end;

  if x.msg_errors <> [] then begin
    let error_codes = List.map (fun err -> sprintf "`%s`" err.err_name) x.msg_errors in
    printer (sprintf "_Possible Error Codes:_ %s"
                   (String.concat ", " error_codes));
    printer "";
  end

let print_field_table_of_obj printer ~is_class_deprecated ~is_class_removed x =
  printer (sprintf "### Fields for class: "^(escape x.name));
  printer "";
  if x.contents=[] then
    printer ("Class "^(escape x.name)^" has no fields.")
  else begin
    printer "|Field               |Type                |Qualifier      |Description                             |";
    printer "|:-------------------|:-------------------|:--------------|:---------------------------------------|";

    let print_field_content printer ({release; qualifier; ty; field_description=description} as y) =
      let wired_name = Datamodel_utils.wire_name_of_field y in
      let descr =
        (if List.exists is_removal_marker y.lifecycle || is_class_removed then "**Removed**. "
        else if List.exists is_deprecation_marker y.lifecycle || is_class_deprecated then "**Deprecated**. "
        else "") ^ (escape description)
      in
      printer (sprintf "|%s|`%s`|%s|%s|"
        (pad_right (escape wired_name) col_width_20)
        (pad_right (of_ty_verbatim ty) (col_width_20 - 2))
        (pad_right (string_of_qualifier qualifier) col_width_15)
        (pad_right descr col_width_40))
    in

    x |> Datamodel_utils.fields_of_obj
    |> List.sort (fun x y -> compare_case_ins (Datamodel_utils.wire_name_of_field x) (Datamodel_utils.wire_name_of_field y))
    |> List.iter (print_field_content printer)
  end

let of_obj printer x =
  printer (sprintf "## Class: %s" (escape x.name));
  printer "";
  let is_class_removed = List.exists is_removal_marker x.obj_lifecycle in
  let is_class_deprecated = List.exists is_deprecation_marker x.obj_lifecycle in
  if is_class_removed then
  begin
    printer "**This class is removed.**";
    printer ""
  end
  else if is_class_deprecated then
  begin
    printer "**This class is deprecated.**";
    printer ""
  end;
  printer (escape x.description);
  printer "";
  print_field_table_of_obj printer ~is_class_deprecated ~is_class_removed x;
  printer "";
  printer (sprintf "### RPCs associated with class: "^(escape x.name));
  printer "";
  if x.messages=[] then
  begin
    printer (sprintf "Class %s has no additional RPCs associated with it." (escape x.name));
    printer ""
  end
  else
    x.messages
    |> List.sort (fun x y -> compare_case_ins x.msg_name y.msg_name)
    |> List.iter (markdown_section_of_message printer ~is_class_deprecated ~is_class_removed)

let print_enum printer = function
  | Enum (name, options) ->
    printer (sprintf "|`enum %s`|                                        |"
      (pad_right name (col_width_40 - 7)));
    printer "|:---------------------------------------|:---------------------------------------|";

    let print_option (opt, description) = printer (sprintf "|`%s`|%s|"
      (pad_right opt (col_width_40 - 2)) (pad_right (escape description) col_width_40)) in

    options |> List.sort (fun (x,_) (y,_) -> compare_case_ins x y) |> List.iter print_option;
    printer "";
  | _ -> ()

let error_doc printer { err_name=name; err_params=params; err_doc=doc } =
  printer (sprintf "#### %s" (escape name));
  printer "";
  printer (escape doc);
  printer "";
  if params = [] then
    printer "No parameters."
  else begin
    printer "_Signature:_";
    printer "```";
    printer (sprintf "%s(%s)" name (String.concat ", " params));
    printer "```"
  end;
  printer ""

let print_all printer api =
  (* Remove private messages that are only used internally (e.g. get_record_internal) *)
  let api = Dm_api.filter (fun _ -> true) (fun _ -> true)
      (fun msg -> match msg.msg_tag with (FromObject (Private _)) -> false | _ -> true) api in
  let system = objects_of_api api |> List.sort (fun x y -> compare_case_ins x.name y.name) in
  let relations = relations_of_api api in

  printer "
# API Reference

## Classes

The following classes are defined:

|Name                |Description                                                           |
|:-------------------|:---------------------------------------------------------------------|";

  let get_descr obj =
    (if List.exists is_removal_marker obj.obj_lifecycle then "**Removed**. "
    else if List.exists is_deprecation_marker obj.obj_lifecycle then "**Deprecated**. "
    else "") ^ (escape obj.description)
  in
  List.iter (fun obj -> printer (sprintf "|`%s`|%s|"
      (pad_right obj.name (col_width_20 - 2)) (pad_right (get_descr obj) col_width_70)))
    system;

  printer "
## Relationships Between Classes

Fields that are bound together are shown in the following table:

|_object.field_                          |_object.field_                          |_relationship_ |
|:---------------------------------------|:---------------------------------------|:--------------|";
  List.iter (function (((a, a_field), (b, b_field)) as rel) ->
      let c = Relations.classify api rel in
      let afield = a^"."^a_field in
      let bfield = b^"."^b_field in
      printer (sprintf "|`%s`|`%s`|%s|"
        (pad_right afield (col_width_40 - 2)) (pad_right bfield (col_width_40 - 2))
        (pad_right (Relations.string_of_classification c) col_width_15))
    ) relations;

  printer "
The following figure represents bound fields (as specified above) diagramatically, using crow's foot notation to specify one-to-one, one-to-many or many-to-many relationships:

![Class relationships](classes.png 'Class relationships')

## Types

### Primitives

The following primitive types are used to specify methods and fields in the API Reference:

|Type    |Description                                 |
|:-------|:-------------------------------------------|
|string  |text strings                                |
|int     |64-bit integers                             |
|float   |IEEE double-precision floating-point numbers|
|bool    |boolean                                     |
|datetime|date and timestamp                          |

### Higher-order types

The following type constructors are used:

|Type              |Description                                             |
|:-----------------|:-------------------------------------------------------|
|_c_ ref           |reference to an object of class _c_                     |
|_t_ set           |a set of elements of type _t_                           |
|(_a &#45;&gt; b_) map     |a table mapping values of type _a_ to values of type _b_|

### Enumeration types

The following enumeration types are used:
";
  let type_comparer x y =
    match x, y with
    | Enum (a, _), Enum (b, _) -> compare_case_ins a b
    | _ -> compare x y
  in
  Types.of_objects system |> List.sort type_comparer |> List.iter (print_enum printer);
  List.iter (fun x -> of_obj printer x) system;

    printer "
## Error Handling

When a low-level transport error occurs, or a request is malformed at the HTTP
or XML-RPC level, the server may send an XML-RPC Fault response, or the client
may simulate the same.  The client must be prepared to handle these errors,
though they may be treated as fatal.  On the wire, these are transmitted in a
form similar to this:

```xml
    <methodResponse>
      <fault>
        <value>
          <struct>
            <member>
                <name>faultCode</name>
                <value><int>-1</int></value>
              </member>
              <member>
                <name>faultString</name>
                <value><string>Malformed request</string></value>
            </member>
          </struct>
        </value>
      </fault>
    </methodResponse>
```

All other failures are reported with a more structured error response, to
allow better automatic response to failures, proper internationalisation of
any error message, and easier debugging.  On the wire, these are transmitted
like this:

```xml
    <struct>
      <member>
        <name>Status</name>
        <value>Failure</value>
      </member>
      <member>
        <name>ErrorDescription</name>
        <value>
          <array>
            <data>
              <value>MAP_DUPLICATE_KEY</value>
              <value>Customer</value>
              <value>eSpiel Inc.</value>
              <value>eSpiel Incorporated</value>
            </data>
          </array>
        </value>
      </member>
    </struct>
```

Note that `ErrorDescription` value is an array of string values. The
first element of the array is an error code; the remainder of the array are
strings representing error parameters relating to that code.  In this case,
the client has attempted to add the mapping _Customer &#45;&gt;
eSpiel Incorporated_ to a Map, but it already contains the mapping
_Customer &#45;&gt; eSpiel Inc._, and so the request has failed.

Each possible error code is documented in the following section.

### Error Codes
";

  (* Sort the errors alphabetically, then generate one section per code. *)
  let errs =
    Hashtbl.fold (fun name err acc -> (name, err) :: acc)
      Datamodel.errors []
  in
  List.iter (error_doc printer)
    (snd (List.split
            (List.sort (fun (n1, _) (n2, _)-> compare n1 n2) errs)))

let json_current_version =
  let time = Unix.gettimeofday () in
  let month, year =
     match String.split ' ' (Date.rfc822_to_string (Date.rfc822_of_float time)) with
     | [ _; _; m; y; _; _ ] -> m,y
     | _ -> failwith "Invalid datetime string"
  in
  `O [
      "api_version_major", `Float (Int64.to_float api_version_major);
      "api_version_minor", `Float (Int64.to_float api_version_minor);
      "current_year", `String year;
      "current_month", `String month;
    ]

let render_template template_file json output_file =
  let templ =  Stdext.Unixext.string_of_file template_file |> Mustache.of_string in
  let rendered = Mustache.render templ json in
  let out_chan = open_out output_file in
  finally (fun () -> output_string out_chan rendered)
          (fun () -> close_out out_chan)

let all api templdir destdir =
  Stdext.Unixext.mkdir_rec destdir 0o755;

  ["cover.mustache", "cover.yaml"; "docbook.mustache", "template.db"] |>
  List.iter (fun (x,y) -> render_template
    (Filename.concat templdir x) json_current_version (Filename.concat destdir y));

  let out_chan = open_out (Filename.concat destdir "api-ref-autogen.md") in
  let printer text =
    fprintf out_chan "%s" text;
    fprintf out_chan "\n"
  in
  finally (fun () -> print_all printer api)
          (fun () -> close_out out_chan)
