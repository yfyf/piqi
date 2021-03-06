(*pp camlp4o -I `ocamlfind query piqi.syntax` pa_labelscope.cmo pa_openin.cmo *)
(*
   Copyright 2009, 2010, 2011, 2012, 2013 Anton Lavrik

   Licensed under the Apache License, Version 2.0 (the "License");
   you may not use this file except in compliance with the License.
   You may obtain a copy of the License at

       http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS,
   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
   See the License for the specific language governing permissions and
   limitations under the License.
*)

 
(*
 * generation of Ocaml type definitions
 *)

module C = Piqic_common
open C
open Iolist


let gen_builtin_type context piqi_type =
  match piqi_type with
    | `any ->
        if context.is_self_spec
        then C.scoped_name context "any"
        else "Piqi_piqi.any"
    | t ->
        C.gen_builtin_type_name t


let gen_typedef_type ?import context typedef =
  let ocaml_name = C.typedef_mlname typedef in
  match import with
    | None ->  (* local typedef *)
        C.scoped_name context ocaml_name
    | Some import ->
        let ocaml_modname = some_of import.Import#ocaml_name in
        (ocaml_modname ^ "." ^ ocaml_name)


(* XXX: check type compatibility *)
let rec gen_type context typename = 
  let import, parent_piqi, typedef = C.resolve_typename context typename in
  match typedef with
    | `alias a ->
        let context = C.switch_context context parent_piqi in
        let ocaml_name = some_of a.A#ocaml_name in
        (* skip cyclic type abbreviations *)
        let ocaml_type = gen_alias_type context a in
        if ocaml_name = ocaml_type (* cyclic type abbreviation? *)
        then ocaml_type
        else gen_typedef_type context typedef ?import
    | _ ->  (* record | variant | list | enum *)
        gen_typedef_type context typedef ?import


and gen_alias_type context a =
  let open Alias in
  match a.ocaml_type, a.typename with
    | Some x, _ -> x
    | None, None ->
        (* this is an alias for a built-in type (piqi_type field must be defined
         * when neither of type and ocaml_type fields are present) *)
        gen_builtin_type context (some_of a.piqi_type)
    | None, Some typename ->
        gen_type context typename


let ios_gen_type context typename =
  ios (gen_type context typename)


let gen_field_type context f =
  let open F in
  match f.typename with
    | None -> ios "bool"; (* flags are represented as booleans *)
    | Some typename ->
        let deftype = ios_gen_type context typename in
        match f.mode with
          | `required -> deftype
          | `optional when f.default <> None && (not f.ocaml_optional) ->
              deftype (* optional + default *)
          | `optional -> deftype ^^ ios " option"
          | `repeated ->
              deftype ^^
              if f.ocaml_array
              then ios " array"
              else ios " list"


let gen_field context f = 
  let open F in
  let fdef = iod " " (* field definition *)
    [
      ios "mutable"; (* defining all fields as mutable at the moment *)
      ios (C.mlname_of_field context f);
      ios ":";
      gen_field_type context f;
      ios ";";
    ]
  in fdef


(* generate record type in record module; see also gen_record' *)
let gen_record_mod context r =
  let modname = String.capitalize (some_of r.R#ocaml_name) in
  let fields = r.R#field in
  let fdefs = (* field definition list *)
    if fields <> []
    then iol (List.map (gen_field context) fields)
    else ios "_dummy: unit"
  in
  let rcons = (* record def constructor *)
    iol [ios "type t = "; ios "{"; fdefs; ios "}"]
  in
  let rdef = iod " "
    [
      ios modname; (* module declaration *)
      ios ":";
        ios "sig"; (* signature *) 
        rcons;
        ios "end";
      ios "=";
        ios modname;
    ]
  in rdef


let gen_option context o =
  let open Option in
  match o.ocaml_name, o.typename with
    | ocaml_name, Some typename -> (
        let import, parent_piqi, typedef = C.resolve_typename context typename in
        match ocaml_name, typedef with
          | None, `variant x ->
              (* NOTE: for some reason, ocaml complains about fully qualified
               * polymorphic variants in recursive modules, so we need to use
               * non-qualified names in this case *)
              if import = None  (* local typedef? *)
              then ios (some_of x.V#ocaml_name)
              else ios_gen_type context typename
          | None, `enum x ->
              if import = None  (* local typedef? *)
              then ios (some_of x.E#ocaml_name)
              else ios_gen_type context typename
          | _ ->
              (* same as C.mlname_of_option but avoid resoving the same type
               * again *)
              let mlname =
                match ocaml_name with
                  | Some n -> n
                  | None -> C.typedef_mlname typedef
              in
              let n = C.gen_pvar_name mlname in
              n ^^ ios " of " ^^ ios_gen_type context typename
        )
    | Some n, None ->
        C.gen_pvar_name n
    | None, None ->
        assert false


let gen_alias context a =
  let open Alias in
  let ocaml_name = some_of a.ocaml_name in
  let ocaml_type = gen_alias_type context a in
  if ocaml_name = ocaml_type (* cyclic type abbreviation? *)
  then [] (* avoid generating cyclic type abbreviations *)
  else [iol [
    ios ocaml_name; ios " = "; ios ocaml_type;
  ]]


let gen_list context l =
  let open L in
  iol [
    ios (some_of l.ocaml_name); ios " = ";
      ios_gen_type context l.typename;
      if l.ocaml_array
      then ios " array"
      else ios " list";
  ]


let gen_options context options =
  let var_defs =
    iod "|" (List.map (gen_option context) options)
  in
  iol [ios "["; var_defs; ios "]"]


let gen_variant context v =
  let open Variant in
  iol [
    ios (some_of v.ocaml_name);
    ios " = ";
    gen_options context v.option;
  ]


let gen_enum context e =
  let open Enum in
  iol [
    ios (some_of e.ocaml_name);
    ios " = ";
    gen_options context e.option;
  ]


let gen_record context r =
  let name = some_of r.R#ocaml_name in
  let modname = String.capitalize name in
  iol [ ios name; ios " = "; ios (modname ^ ".t") ]


let gen_typedef context typedef =
  match typedef with
    | `record t -> [gen_record context t]
    | `variant t -> [gen_variant context t]
    | `enum t -> [gen_enum context t]
    | `list t -> [gen_list context t]
    | `alias t -> gen_alias context t


let gen_mod_typedef context typedef =
  match typedef with
    | `record r ->
        [gen_record_mod context r]
    (* XXX: generate modules for variants? *)
    | _ -> []


let gen_typedefs context (typedefs:T.typedef list) =
  let top_modname = C.top_modname context in
  (* generated typedefs that must be wrapped into ocaml modules *)
  let mod_defs = U.flatmap (gen_mod_typedef context) typedefs in
  (* generated the rest of typedefs *)
  let other_defs = U.flatmap (gen_typedef context) typedefs in
  let other_defs_mod = iod " "
    [
      ios top_modname; (* module declaration *)
      ios ":";
        ios "sig";  (* signature *) 

        if other_defs = []
        then iol []
        else iol [
          ios "type ";
          iod " type " other_defs;
        ];

        ios "end";
      ios "="; ios top_modname;
    ]
  in
  let modules = [other_defs_mod] @ mod_defs in
  let code = iol [
    ios "module rec ";
    iod " and " modules;
  ]
  in
  iod " " [
    code;
    eol;
  ]


let gen_import context import =
  let open Import in
  let index = C.resolve_import context import in
  let piqi = index.i_piqi in
  iod " " [
    ios "module"; ios (some_of import.ocaml_name); ios "=";
        ios (some_of piqi.P#ocaml_module);
    eol;
  ]


let gen_imports context l =
  let l = List.map (gen_import context) l in
  iol l


(* NOTE: for some reason, ocaml complains about fully qualified polymorphic
 * variants in recursive modules, so instead of relying on OCaml, we need to
 * preorder variants ourselves without relying on OCaml to figure out the order
 * automatically *)
let order_variants context l =
  (* topologically sort local variant defintions *)
  let cycle_visit def =
    C.error ("cyclic OCaml variant definition: " ^ typedef_name def)
  in
  let get_adjacent_vertixes = function
    | `variant v ->
        (* get the list of included variants *)
        U.flatmap (fun o ->
          match o.O#typename with
            | Some typename when o.O#ocaml_name = None ->
                let import, parent_piqi, typedef = C.resolve_typename context typename in
                (match typedef with
                  | ((`variant _) as typedef)
                  | ((`enum _) as typedef) ->
                      if import <> None (* imported? *)
                      then [] (* omit any imported definitions *)
                      else [typedef]
                  | _ -> []
                )
            | _ -> []
        ) v.V#option
    | _ -> []
  in
  Piqi_graph.tsort l get_adjacent_vertixes ~cycle_visit


(* make sure we define aliases for built-in ocaml types first; some aliases
 * (e.g. float) can override the default OCaml type names which results in
 * cyclic type definitions without such ordering *)
let order_aliases l =
  let rank def =
    match def with
      | `alias x ->
          if C.is_builtin_alias x
          then
            (* aliases of built-in OCaml types go first *)
            if x.A#ocaml_type <> None then 1 else 2
          else 100
      | _ ->
          assert false
  in
  let compare_alias a b =
    rank a - rank b
  in
  List.stable_sort compare_alias l


let order_typedefs context typedefs =
  (* we apply this specific ordering only to variants, to be more specific --
   * only to those variants that include other variants by not specifying tags
   * for the options *)
  let variants, rest =
    List.partition (function
      | `variant _ | `enum _ -> true
      | _ -> false)
    typedefs
  in
  let aliases, rest =
    List.partition (function
      | `alias _ -> true
      | _ -> false)
    rest
  in
  (* return the updated list of definitions with sorted variants and aliases *)
  (order_aliases aliases) @ (order_variants context variants) @ rest


let gen_piqi context =
  let piqi = context.piqi in
  let typedefs = order_typedefs context piqi.P#typedef in
  iol [
    gen_imports context piqi.P#import;
    gen_typedefs context typedefs;
  ]

