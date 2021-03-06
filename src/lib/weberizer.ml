(* Parse an HTML file with template annotations and outputs an OCaml
   module that allows to fill the "holes" and output the final file.
*)

open Format
open Neturl

type html = Nethtml.document list

(* Helper functions
 ***********************************************************************)

let identity x = x

let html_encode = Netencoding.Html.encode ~in_enc:`Enc_utf8 ()

let is_lowercase c = 'a' <= c && c <= 'z'
let is_valid_char c =
  ('0' <= c && c <= '9') || is_lowercase c || ('A' <= c && c <= 'Z') || c = '_'

let rec is_digit_or_letter s i len =
  i >= len || (is_valid_char s.[i] && is_digit_or_letter s (i+1) len)

(* Check that the string is a valid OCaml identifier. *)
let valid_ocaml_id s =
  let len = String.length s in
  len > 0 && is_lowercase s.[0] && is_digit_or_letter s 1 len

let is_space c = c = ' ' || c = '\t' || c = '\n' || c = '\r'

(* Return the first index [j >= i] such that [s.[j]] is not a space.  *)
let rec skip_spaces s i len =
  if i >= len then len
  else if is_space s.[i] then skip_spaces s (i + 1) len
  else i

(* Split the string [s] at spaces (one or several contiguous spaces).
   The way to have a block with spaces or an empty argument is to
   quote it with double quotes. *)
let rec split_on_spaces s =
  let len = String.length s in
  let i = skip_spaces s 0 len in
  get_split_string s i i len
and get_split_string s i0 i len =
  if i >= len then
    if i0 >= len then [] else [String.sub s i0 (len - i0)]
  else if is_space s.[i] then
    let v = String.sub s i0 (i - i0) in
    let i = skip_spaces s (i + 1) len in
    v :: get_split_string s i i len
  else if s.[i] = '"' then get_quoted_string s (i + 1) (i + 1) len
  else get_split_string s i0 (i + 1) len
and get_quoted_string s i0 i len =
  if i >= len then failwith(sprintf "Unterminated quoted string in %S" s)
  else if s.[i] = '"' && s.[i-1] <> '\\' then
    let v = String.sub s i0 (i - i0) in
    let i = skip_spaces s (i + 1) len in
    v :: get_split_string s i i len
  else get_quoted_string s i0 (i + 1) len

let rec index_nospace s i =
  if i >= String.length s then i
  else if is_space s.[i] then index_nospace s (i+1)
  else i

let rec index_last_nospace s i0 i =
  if i < i0 then i
  else if is_space s.[i] then index_last_nospace s i0 (i - 1)
  else i

let strip_spaces s =
  let i_last = String.length s - 1 in
  let i0 = index_nospace s 0 in
  let i1 = index_last_nospace s i0 i_last in
  if i0 = 0 && i1 = i_last then s
  else String.sub s i0 (i1 - i0 + 1)

let rec is_prefix_loop p s i len_p =
  i >= len_p || (p.[i] = s.[i] && is_prefix_loop p s (i + 1) len_p)

let is_prefix p s =
  let len_p = String.length p in
  len_p <= String.length s  &&  is_prefix_loop p s 0 len_p

let rec end_with_loop s p i ofs =
  i < 0 || (p.[i] = s.[ofs + i] && end_with_loop s p (i-1) ofs)

let end_with s p =
  let len_p = String.length p and len_s = String.length s in
  len_p <= len_s  &&  end_with_loop s p (len_p - 1) (len_s - len_p)


let buffer_add_file buf fn =
  let fh = open_in fn in
  let b = String.create 4096 in
  let r = ref 1 in (* enter the loop *)
  while !r > 0 do
    r := input fh b 0 4096;
    Buffer.add_substring buf b 0 !r
  done;
  close_in fh

let string_of_file fn =
  let buf = Buffer.create 4096 in
  buffer_add_file buf fn;
  Buffer.contents buf

(* Parse strings
 *************************************************************************)

module Var =
struct
  (* Type of variables in HTML templates. *)
  type ty = HTML | String | Fun_html | Fun

  let type_to_string = function
    | HTML -> "html"
    | String -> "string"
    | Fun_html -> "fun_html"
    | Fun -> "fun"

  let type_code = function
    | HTML -> "html"
    | String -> "string"
    | Fun_html -> "(string list -> html)"
    | Fun -> "(string list -> string)"

  (* Characteristics of a variable *)
  type t = { mutable ty: ty;             (* var type *)
           }

  (* name -> t *)
  type set = (string, t) Hashtbl.t

  let make () = (Hashtbl.create 10 : set)
  let ty h v = (Hashtbl.find h v).ty

  let write_code_eval fm v args =
    fprintf fm "(Eval.%s t [" v;
    List.iter (fun a -> fprintf fm "%S;" a) args;
    fprintf fm "])"

  (* See [compile_html] where [eval] and [t] are defined in the
     generated module. *)
  let write_code_html fm h v args = match ty h v with
    | HTML -> fprintf fm "Eval.%s t" v
    | String -> fprintf fm "[Nethtml.Data(Eval.%s t)]" v
    | Fun_html -> write_code_eval fm v args;
    | Fun ->
        fprintf fm "[Nethtml.Data(";
        write_code_eval fm v args;
        fprintf fm ")]"

  let write_code_empty fm h v = match ty h v with
    | HTML | Fun_html -> fprintf fm "[]"
    | String | Fun -> fprintf fm "\"\""

  (* Write a let-binding if needed to avoid multiple evaluations of a function.
     @return the variable name to use. *)
  let binding_no = ref 0
  let write_binding fm h v args = match ty h v with
    | HTML | String -> sprintf "Eval.%s t" v
    | Fun_html | Fun ->
        incr binding_no;
        let n = !binding_no in
        fprintf fm "let ocaml_template__%i = " n;
        write_code_eval fm v args;
        fprintf fm " in@\n";
        "ocaml_template__" ^ string_of_int n

  (* Add a new variable.  In case of conflicting types, use the
     "lower" type compatible with both. *)
  let add (h:set) v ty =
    try
      let v' = Hashtbl.find h v in
      match v'.ty, ty with
      | (HTML | String), (Fun_html | Fun) | (Fun_html | Fun), (HTML | String) ->
          failwith(sprintf "The identifier %S cannot be used both as a \
		variable and a function" v)
      | HTML, String | String, HTML -> v'.ty <- String
      | Fun_html, Fun | Fun, Fun_html -> v'.ty <- Fun
      | HTML, HTML | String, String | Fun_html, Fun_html | Fun, Fun -> ()
    with Not_found ->
      Hashtbl.add h v { ty = ty }

  let iter (h:set) f = Hashtbl.iter f h

  (* Iterates on the keys in alphabetical order. *)
  let iter_ab (h:set) f =
    (*  *)
    let l = Hashtbl.fold (fun v t l -> (v, t) :: l) h [] in
    let l = List.sort (fun (v1,_) (v2,_) -> String.compare v1 v2) l in
    List.iter (fun (v,t) -> f v t) l
end

type string_or_var =
  | String of string                    (* literal string *)
  | Var of string                       (* Var(ident) *)
  | Fun of string * string list         (* Fun(ident, args) *)
type subst_string = string_or_var list

let rec parse_string_range add_string add_var acc s i0 i len_s =
  if i >= len_s then
    let len = i - i0 in
    if len = 0 then acc else add_string acc (String.sub s i0 len)
  else if i + 1 < len_s && s.[i] = '$' && s.[i+1] = '{' then
    let len = i - i0 in
    if len = 0 then parse_var add_string add_var acc s (i+2) (i+2) len_s
    else (
      let acc = add_string acc (String.sub s i0 len) in
      parse_var add_string add_var acc s (i+2) (i+2) len_s
    )
  else
    parse_string_range add_string add_var acc s i0 (i+1) len_s
and parse_var add_string add_var acc s i0 i len_s =
  if i >= len_s then
    invalid_arg(sprintf "Missing '}' to close the variable %S"
                  (String.sub s i0 (len_s - i0)))
  else if s.[i] = '}' then (
    let acc = add_var acc (String.sub s i0 (i - i0)) in
    parse_string_range add_string add_var acc s (i+1) (i+1) len_s
  )
  else parse_var add_string add_var acc s i0 (i+1) len_s


let decode_var h v =
  match split_on_spaces v with
  | [] | "" :: _ -> invalid_arg "Empty variables are not allowed"
  | [v] ->
      if valid_ocaml_id v then (Var.add h v Var.String; Var v)
      else invalid_arg(sprintf "Variable %S is not a valid OCaml identifier" v)
  | v :: args ->
      if valid_ocaml_id v then (Var.add h v Var.Fun; Fun(v, args))
      else invalid_arg(sprintf "Function name %S is not valid" v)

let parse_string h s =
  let add_string l s = String s :: l in
  let add_var l v = decode_var h v :: l in
  List.rev(parse_string_range add_string add_var [] s 0 0 (String.length s))


(* Parse Nethtml document : search for variables
 ***********************************************************************)

type strip = [ `No | `Yes | `If_empty ]

type document =
  | Element of string * (string * subst_string) list * document list
  | Data of subst_string
  | Content of string * (string * subst_string) list
      * strip * string * string list
      (* Content(el, args, strip default, var, args) : content replacement *)

(* Accumulator keeping given OCaml arguments *)
type ocaml_args = {
  mutable var: string; (* var name or "" *)
  mutable args: string list; (* possible function arguments *)
  mutable strip: strip;
}

let is_ocaml_arg s =
  String.length s > 3 && s.[0] = 'm' && s.[1] = 'l' && s.[2] = ':'

(* [split_args_set_ml h ml [] all] go through the arguments [all],
   record the "ml:*" arguments in [ml] and returns the other
   arguments.  These other arguments possibly contain variables.  This
   is the work of [parse_string] to replace them. *)
let rec split_args_set_ml parse_string ml args all = match all with
  | [] -> args
  | (arg, v) :: tl ->
    if is_ocaml_arg arg then (
      begin
        let a = String.sub arg 3 (String.length arg - 3) in
        if a = "content" then
          match split_on_spaces v with
          | v :: args when valid_ocaml_id v ->
            ml.var <- v;  ml.args <- args
          | _ -> failwith(sprintf "The variable name %S is not valid" v)
        else if a = "strip" then
          let v = strip_spaces v in
          ml.strip <- (if v = "ifempty" || v = "if empty" then `If_empty
            else `Yes)
        else if a = "replace" then
          match split_on_spaces v with
          | v :: args when valid_ocaml_id v ->
            ml.var <- v;  ml.args <- args;  ml.strip <- `Yes
          | _ -> failwith(sprintf "The variable name %S is not valid" v)
      end;
      split_args_set_ml parse_string ml args tl
    )
    else
      split_args_set_ml parse_string ml ((arg, parse_string v) :: args) tl

let split_args parse_string args all =
  let ml = { var = "";  args = [];  strip = `No } in
  let args = split_args_set_ml parse_string ml args all in
  args, ml

let read_html fname =
  let fh = open_in fname in
  let tpl = (Nethtml.parse_document (Lexing.from_channel fh)
               ~dtd:Nethtml.relaxed_html40_dtd) in
  close_in fh;
  tpl

let rec parse_element h html = match html with
  | Nethtml.Data(s) -> [Data(parse_string h s)]
  | Nethtml.Element(el, args, content) ->
    let args, ml = split_args (parse_string h) [] args in
    if ml.var = "" then
      [Element(el, args, parse_html h content)]
    else if ml.var = "include" then (
      let content = List.concat(List.map (read_and_parse h) ml.args) in
      match ml.strip with
      | `No -> [Element(el, args, content)]
      | `Yes -> content
      | `If_empty -> (if content = [] then []
                     else [Element(el, args, content)])
    )
    else (
      Var.add h ml.var (if ml.args = [] then Var.HTML else Var.Fun_html);
      [Content(el, args, ml.strip, ml.var, ml.args)]
    )

and parse_html h html = List.concat(List.map (parse_element h) html)

and read_and_parse h fn =
  if Filename.check_suffix fn ".html" || Filename.check_suffix fn ".htm" then
    parse_html h (read_html fn)
  else
    [Data[String(html_encode (string_of_file fn))]]


(* Output to a static module
 ***********************************************************************)

let write_string_or_var fh s = match s with
  | String s -> fprintf fh "%S" s
  | Var v -> fprintf fh "Eval.%s t" v
  | Fun(f, args) ->
      fprintf fh "Eval.%s t " f;
      List.iter (fun v -> fprintf fh "%S " v) args

let write_subst_string fh s = match s with
  | [] -> fprintf fh "\"\""
  | [s] -> write_string_or_var fh s
  | [s1; s2] ->
      write_string_or_var fh s1; fprintf fh "@ ^ ";
      write_string_or_var fh s2
  | [s1; s2; s3] ->
      write_string_or_var fh s1; fprintf fh "@ ^ ";
      write_string_or_var fh s2; fprintf fh "@ ^ ";
      write_string_or_var fh s3
  | _ ->
      fprintf fh "@[String.concat \"\" [";
      List.iter (fun s -> write_string_or_var fh s; fprintf fh ";@ ") s;
      fprintf fh "]@]@,"

let write_args fh args =
  fprintf fh "@[<1>[";
  List.iter (fun (n,v) ->
               fprintf fh "(%S, " n;
               write_subst_string fh v;
               fprintf fh ");@ "
            ) args;
  fprintf fh "]@]"

let rec write_rendering_fun fm h tpl =
  fprintf fm "@[<2>let render t =@\n";
  write_rendering_list fm h tpl;
  fprintf fm "@]@\n"
and write_rendering_list fm h tpl =
  fprintf fm "@[<1>[";
  List.iter (fun tpl -> write_rendering_node fm h tpl) tpl;
  fprintf fm "]@]@,"
and write_rendering_node fm h tpl = match tpl with
  | Data s ->
      fprintf fm "Nethtml.Data(";
      write_subst_string fm s;
      fprintf fm ");@ ";
  | Element(el, args, content) ->
      fprintf fm "@[<2>Nethtml.Element(%S,@ " el;
      write_args fm args;
      fprintf fm ",@ ";
      write_rendering_list fm h content;
      fprintf fm ");@]@ "
  | Content(el, args, strip, var, fun_args) ->
      (* We are writing a list.  If this must be removed, concatenate
         with left and right lists.  FIXME: this is not ideal and
         maybe one must move away from Nethtml representation? *)
      (match strip with
       | `No ->
          fprintf fm "@[<2>Nethtml.Element(%S,@ " el;
          write_args fm args;
          fprintf fm ",@ ";
          Var.write_code_html fm h var fun_args;
          fprintf fm ");@]@ "
       | `Yes ->
          fprintf fm "]@ @@ ";
          Var.write_code_html fm h var fun_args;
          fprintf fm "@ @@ ["
       | `If_empty ->
          fprintf fm "]@ @@ @[<1>(";
          let bound_var = Var.write_binding fm h var fun_args in
          fprintf fm "if %s = " bound_var;
          Var.write_code_empty fm h var;
          fprintf fm " then []@ else @[<2>[Nethtml.Element(%S,@ " el;
          write_args fm args;
          fprintf fm ",@ %s)]@])@]@ @@ [" bound_var
      )
;;

let compile_html ?trailer_ml ?trailer_mli ?(hide=[]) ?module_name fname =
  let module_name = match module_name with
    | None -> (try Filename.basename(Filename.chop_extension fname)
              with _ -> fname)
    | Some n -> n (* FIXME: check valid module name *) in
  (* Parse *)
  let h = Var.make() in
  let tpl = read_and_parse h fname in
  (* Output implementation *)
  let fh = open_out (module_name ^ ".ml") in
  let fm = formatter_of_out_channel fh in
  fprintf fm "(* Module generated from the template %s. *)@\n@\n" fname;
  fprintf fm "type html = Nethtml.document list@\n@\n";
  fprintf fm "@[<2>type t = {@\n";
  Var.iter h (fun v t ->
                fprintf fm "%s: %s delay;@\n" v (Var.type_code t.Var.ty);
             );
  fprintf fm "@]}@\n@[<2>and 'a delay =@\n\
              | Val of 'a@\n\
              | Delay of (t -> 'a) * 'a delay\
              @]@\n@\n";
  (* See [Var.type_to_string] for the names: *)
  fprintf fm "let default_html = Val []\n";
  fprintf fm "let default_string = Val \"\"\n";
  fprintf fm "let default_fun_html = (fun _ -> Val [])\n";
  fprintf fm "let default_fun = Val(fun _ -> \"\")\n";
  fprintf fm "let empty = {\n";
  Var.iter h begin fun v t ->
    fprintf fm "  %s = default_%s;\n" v (Var.type_to_string t.Var.ty);
  end;
  fprintf fm "}\n\n";
  Var.iter h (fun v _ ->
                fprintf fm "let %s t v = { t with %s = Val v }\n" v v
             );
  (* Submodule to access the values independently of the
     representation of a template.  Use an abstract type to force the
     use of the [Set] module to be able to access the values through
     [Get] functions. The coercing submodule is named [Variable] to
     have readable error messages. *)
  fprintf fm "\n@[<2>module Variable : sig@\ntype get@\n";
  fprintf fm "@[<2>module Eval : sig@\n";
  Var.iter h (fun v t ->
              fprintf fm "val %s : t -> %s@\n" v (Var.type_code t.Var.ty)
             );
  fprintf fm "end@]@\n@[<2>module Get : sig@\n";
  Var.iter h (fun v t ->
              fprintf fm "val %s : get -> %s@\n" v (Var.type_code t.Var.ty)
             );
  fprintf fm "end@]@\n@[<2>module Set : sig@\n";
  Var.iter h (fun v t ->
              fprintf fm "val %s : t -> (get -> %s) -> t@\n"
                      v (Var.type_code t.Var.ty)
             );
  fprintf fm "end@]@\nend = struct@\n";
  fprintf fm "@[<2>module Eval = struct@\n";
  (* [Eval.x] must restore the previous value of [x] in the template
     for [f] in case [Get.x] is called again in inside [f] (we do not
     want to rerun [f] as it would create an infinite loop). *)
  let get v _ =
    fprintf fm "@[<2>let %s t = match t.%s with@\n\
                | Val a -> a@\n\
                | Delay (f, previous) -> f { t with %s = previous }\
                @]@\n" v v v in
  Var.iter h get;
  fprintf fm "@]end@\ntype get = t@\n";
  (* [Get.x] = [Eval.x] except that there is a type coercion to
     prevent misuse. *)
  fprintf fm "module Get = Eval@\n";
  fprintf fm "@[<2>module Set = struct@\n";
  let set v _ =
    fprintf fm "let %s t f = { t with %s = Delay(f, t.%s) }@\n" v v v in
  Var.iter h set;
  fprintf fm "end@]@\nend@]@\nopen Variable@\n@\n";
  write_rendering_fun fm h tpl;
  begin match trailer_ml with
        | None -> ()
        | Some txt ->
           fprintf fm "(* ---------- Trailer -------------------- *)@\n%s" txt
  end;
  fprintf fm "@?"; (* flush *)
  close_out fh;
  (* Output interface *)
  let fh = open_out (module_name ^ ".mli") in
  let fm = formatter_of_out_channel fh in
  fprintf fm "(* Module interface generated from the template %s. *)\n\n" fname;
  fprintf fm "type html = Nethtml.document list\n\n";
  fprintf fm "type t\n  (** Immutable template. *)\n\n";
  fprintf fm "val empty : t\n";
  fprintf fm "  (** Empty (unfilled) template. *)\n";
  fprintf fm "val render : t -> html@\n";
  fprintf fm "  (** Renders the template as an HTML document. *)\n\n";
  Var.iter_ab h begin fun v t ->
    if not(List.mem v hide) then
      fprintf fm "val %s : t -> %s -> t\n" v (Var.type_code t.Var.ty)
  end;
  begin match trailer_mli with
  | None -> ()
  | Some txt -> fprintf fm "\n\n%s" txt
  end;
  fprintf fm "@?"; (* flush *)
  close_out fh


(* Compile an HTML file, possibly with some extra code in .html.ml
 *************************************************************************)

let content_of_file file =
  let buf = Buffer.create 4096 in
  (* Add a directive to refer to the original file for errors *)
  Buffer.add_string buf ("# 1 \"" ^ String.escaped file ^ "\"\n");
  buffer_add_file buf file;
  Buffer.contents buf

(* Return the content of [file] if it exists or [None] otherwise. *)
let maybe_content file =
  if Sys.file_exists file then Some(content_of_file file) else None

let copy_newlines s =
  let buf = Buffer.create 16 in
  for i = Str.match_beginning() to Str.match_end() - 1 do
    if s.[i] = '\n' || s.[i] = '\r' then Buffer.add_char buf s.[i]
  done;
  Buffer.contents buf

(* Looks for variable names to hide in the mli, declared with "@hide
   var".  One suppresses the comment but preserve the number of lines
   in order for the errors to point to the correct location in the
   original file. *)
let hide_re = Str.regexp "(\\* *@hide +\\([a-zA-Z_]+\\) *\\*) *\n?"
let vars_to_hide mli =
  match mli with
  | None -> [], mli
  | Some mli ->
      let i = ref 0 in
      let acc = ref [] in
      try
        while true do
          i := Str.search_forward hide_re mli !i;
          acc := Str.matched_group 1 mli :: !acc;
          incr i;
        done;
        assert false
      with Not_found ->
        !acc, Some(Str.global_substitute hide_re copy_newlines mli)

let compile ?module_name f =
  let trailer_ml = maybe_content (f ^ ".ml") in
  let trailer_mli = maybe_content (f ^ ".mli") in
  let hide, trailer_mli = vars_to_hide trailer_mli in
  compile_html ?trailer_ml ?trailer_mli ~hide ?module_name f


(* Parsing with direct substitution
 ***********************************************************************)

module Binding =
struct

  type data =
    | Html of html
    | String of string
    | Fun_html of (< content: html; page: html > -> string list -> html)
    | Fun of (< page: html > -> string list -> string)

  type t = { var: (string, data) Hashtbl.t;
             mutable on_error: string (* var *) -> string list -> exn -> unit }

  let make () =
    let on_error var args e =
      let v = String.concat " " (var :: args) in
      Printf.eprintf "ERROR: Weberizer.Binding: $(%s) raised %S.\n%!"
                     v (Printexc.to_string e) in
    { var = Hashtbl.create 20; on_error }

  let copy b = { var = Hashtbl.copy b.var;  on_error = b.on_error }

  let on_error b f = b.on_error <- f

  let string b var s = Hashtbl.add b.var var (String s)
  let html b var h = Hashtbl.add b.var var (Html h)
  let fun_html b var f = Hashtbl.add b.var var (Fun_html f)
  let fun_string b var f = Hashtbl.add b.var var (Fun f)

  exception Std_Not_found = Not_found
  exception Not_found of string

  (* Error message included in the HTML and possibly displayed to the
      user.  Should not contain confidential information. *)
  let error_message var args exn =
    let v = String.concat " " (var :: args) in
    Printf.sprintf "The function associated to $(%s) raised the exception %S"
                   v (Printexc.to_string exn)

  let html_error_message var args exn =
    [Nethtml.Element("span", ["class", "weberizer-error"],
                     [Nethtml.Data(error_message var args exn)])]

  let find b var =
    try Hashtbl.find b.var var
    with Std_Not_found -> raise(Not_found var)

  let fail_not_a_fun var =
    invalid_arg(sprintf "%S is bound to a variable but used \
		as a function in the HTML template" var)

  let subst_to_string b ctx var args =
    match find b var with
    | String s -> (match args with [] -> html_encode s | _ -> fail_not_a_fun var)
    | Fun f ->
       (try html_encode(f ctx args)
        with e ->
          b.on_error var args e;
          error_message var args e)
    | Html _ | Fun_html _ ->
       invalid_arg(sprintf "Weberizer.Binding: The binding %S returns HTML \
                            but is used at a place where only strings are \
                            allowed" var)

  let subst_to_html b ctx var args =
    match find b var with
    | String s -> (match args with
                  | [] -> [Nethtml.Data(html_encode s)]
                  | _ -> fail_not_a_fun var)
    | Html h -> h
    | Fun_html f ->
       (try f ctx args
        with e ->
          b.on_error var args e;
          html_error_message var args e)
    | Fun f ->
       (try  [Nethtml.Data(html_encode(f (ctx :> < page: html >) args))]
        with e ->
          b.on_error var args e;
          html_error_message var args e)
end

(* Perform all includes first -- so other bindings receive the HTML
   were the substitutions have been made.  All relative filenames are
   resolved w.r.t. the [base]. *)
let rec perform_includes_el base = function
  | Nethtml.Data(_) as e -> [e]
  | Nethtml.Element(el, args0, content0) ->
     let args, ml = split_args identity [] args0 in
     if ml.var <> "include" then
       [Nethtml.Element(el, args0, perform_includes base content0)]
     else
       (* Use the filename location as the new base since this file
          was prepared without knowing from where it will be included. *)
       let include_file fn =
         let fn = if Filename.is_relative fn then Filename.concat base fn
                  else fn in
         if Filename.check_suffix fn ".html"
            || Filename.check_suffix fn ".htm" then
           perform_includes (Filename.dirname fn) (read_html fn)
         else
           [Nethtml.Data(html_encode (string_of_file fn))]  in
       let content = List.concat(List.map include_file ml.args) in
       match ml.strip with
       | `No | `If_empty -> [Nethtml.Element(el, args, content)]
       | `Yes -> content

and perform_includes base html =
  List.concat(List.map (perform_includes_el base) html)


let subst_var b ctx v =
  match split_on_spaces v with
  | [] | "" :: _ -> invalid_arg "Empty variables are not allowed"
  | v :: args ->
      if valid_ocaml_id v then Binding.subst_to_string b ctx v args
      else invalid_arg(sprintf "Function name %S is not valid" v)

(* Substitute variables in HTML elements arguments. *)
let subst_arg bindings ctx s =
  let buf = Buffer.create 100 in
  let add_string _ s = Buffer.add_string buf s in
  let add_var _ v = Buffer.add_string buf (subst_var bindings ctx v) in
  parse_string_range add_string add_var () s 0 0 (String.length s);
  Buffer.contents buf

let subst_to_html bindings ctx s =
  let add_string l s = Nethtml.Data s :: l in
  let add_var l v = Nethtml.Data(subst_var bindings ctx v) :: l in
  List.rev(parse_string_range add_string add_var [] s 0 0 (String.length s))

let rec subst_html bindings ctx html =
  List.concat(List.map (subst_element bindings ctx) html)

and subst_element bindings ctx = function
  | Nethtml.Data s -> subst_to_html bindings ctx s
  | Nethtml.Element(el, args, content) ->
      let args, ml = split_args (subst_arg bindings ctx) [] args in
      if ml.var = "" then
        (* No OCaml variable, recurse. *)
        [Nethtml.Element(el, args, subst_html bindings ctx content)]
      else
        (* "include"s are supposed to be done already. *)
        let ctx = object
            method page = ctx#page
            method content = content
          end in
        let new_content = Binding.subst_to_html bindings ctx ml.var ml.args in
        match ml.strip with
        | `No -> [Nethtml.Element(el, args, new_content)]
        | `Yes -> new_content
        | `If_empty -> (if new_content = [] then []
                       else [Nethtml.Element(el, args, new_content)])

(* Function bindings receive the pristine HTML in case they want to
   parse it to generate data (e.g. a table of content). *)
let subst ?base bindings html =
  let base = match base with None -> Sys.getcwd() | Some p -> p in
  let html = perform_includes base html in
  subst_html bindings (object method page = html end) html

let read ?base ?bindings fname =
  let base = match base with None -> Filename.dirname fname | Some p -> p in
  let html = perform_includes base (read_html fname) in
  match bindings with
  | None -> html
  | Some b -> subst ~base b html


(* Utilities
 ***********************************************************************)

let write_html ?(doctype=true) ?(perm=0o644) html fname =
  let mode = [Open_creat; Open_wronly; Open_trunc; Open_text] in
  let perm = perm land 0o666 in (* rm exec bits *)
  let oc = new Netchannels.output_channel (open_out_gen mode perm fname) in
  if doctype then
    oc#output_string
      "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Strict//EN\"
          \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd\">";
  Nethtml.write oc html ~dtd:Nethtml.html40_dtd;
  oc#close_out()

(* [body_of doc] returns the content of the <body> (if any) of [doc]. *)
let rec add_body_of_element acc el = match el with
  | Nethtml.Data _ -> acc
  | Nethtml.Element("body", _, content) -> acc @ content
  | Nethtml.Element(_, _, content) -> get_body_of acc content
and get_body_of acc content = List.fold_left add_body_of_element [] content

let body_of html =
  let body = get_body_of [] html in
  if body = [] then html else body

let rec concat_data c =
  String.concat "" (List.map data c)
and data = function
  | Nethtml.Data s -> s
  | Nethtml.Element(_, _, c) -> concat_data c

(* Retrieve the <title> of HTML.  We use "^" to concatenate titles
   because we expect few of them (only one). *)
let rec get_title acc html =
  List.fold_left get_title_el acc html
and get_title_el acc e = match e with
  | Nethtml.Element("title", _, content) -> concat_data content ^ acc
  | Nethtml.Element(_, _, content) -> get_title acc content
  | Nethtml.Data _ -> acc

let title_of html = get_title "" html

module Path =
struct
  (* Constructing navigation bars will request again and again the
     name associated to a directory in a given language.  In order not
     to access the disk too frequently, one caches this information. *)
  type t = {
    name : string;       (* the name of the directory/file *)
    is_dir : bool;       (* whether this path component is a dir *)
    full_path : string;  (* full path to the dir/file (included) *)
    from_base : string;  (* relative path from base *)
    to_base : string;    (* relative path from the dir to the base,
                            ends with '/'. *)
    parent : t option; (* the parent dir, or [None] if base dir *)
    mutable desc : (string * string) list;
    (* cache; associative list: lang -> descriptive name *)
  }

  (** Apply [f] to all components of the path [p] exept the base one. *)
  let rec fold_left f a p = match p.parent with
    | None -> a (* base dir *)
    | Some d -> fold_left f (f a p) d

  let make base =
    let len = String.length base in
    let base =
      if len > 0 && base.[len - 1] = '/' then String.sub base 0 (len - 1)
      else base in
    { name  = Filename.basename base;  is_dir = true;
      full_path = base;  from_base = "";
      to_base = "./"; (* must end with "/" *)
      parent = None;  desc = [] }

  let base = make "."

  let filename p = p.name (* may be the dir name, but only files will
                             be given to the library user. *)
  let from_base p = p.from_base

  let parent p = match p.parent with
    | None -> failwith "Weberizer.Path.parent: Base directory, no parent"
    | Some d -> d

  let rec from_base_split_loop acc p = match p.parent with
    | None -> acc (* base dir, not in path *)
    | Some d -> from_base_split_loop (p.name :: acc) d

  let from_base_split p = from_base_split_loop [] p

  let to_base p = p.to_base

  let in_base p = match p.parent with
    | None -> true
    | Some d -> d.parent = None

  let to_base_split p = match p.parent with
      (* Beware that the split version of "../" is [".."; ""] (but the
         split of ".." is [".."]). *)
    | None -> [] (* in base dir *)
    | Some d ->
        match d.parent with
        | None -> [] (* [p] is a filename in the base directory *)
        | Some _ ->
            (* Ignore the component [p] considered to be a filename. *)
            fold_left (fun acc _ -> ".." :: acc) [""] d

  let full p = p.full_path

  (*
   * Titles for navigation.
   *)

  (* Retrieve the <title> of fname (returns [""] if none is found). *)
  let title_of_file fname =
    try get_title "" (read_html fname)
    with Sys_error _ -> ""

  let lang_re =
    Str.regexp "\\([a-zA-Z_ ]+\\)\\(\\.\\([a-z]+\\)\\)?\\(\\.[a-zA-Z_ ]+\\)"
  let base_lang_ext_of_filename f =
    if Str.string_match lang_re f 0 then
      (Str.matched_group 1 f,
       (try String.lowercase(Str.matched_group 3 f) with _ -> ""),
       Str.matched_group 4 f)
    else f, "", ""

  let language p =
    let f = filename p in
    if Str.string_match lang_re f 0 then
      (try String.lowercase(Str.matched_group 3 f) with _ -> "")
    else ""

  (** Returns the descriptive name of the file/dir pointed by [p] for
      the language [lang]. *)
  let description_lang p lang =
    try List.assoc lang p.desc
    with Not_found ->
      let desc =
        if p.is_dir then
          (* Directory, look for index.<lang>.html *)
          let index = p.full_path ^ (if lang = "" then "/index.html"
                                     else "/index." ^ lang ^ ".html") in
          let title = title_of_file index in
          if title = "" then String.capitalize p.name else title
        else
          let title = title_of_file p.full_path in
          if title = "" then
            let base, _, _ = base_lang_ext_of_filename p.name in
            String.capitalize base
          else title in
      p.desc <- (lang, desc) :: p.desc;
      desc

  (* [from_last_dir] is a relative path from the final directory
     pointed by [p] to each path component. *)
  let rec navigation_dir from_last_dir acc p lang = match p.parent with
    | None -> (description_lang p lang, from_last_dir) :: acc (* base dir *)
    | Some d ->
        let from_d = from_last_dir ^ "../" in
        let acc = (description_lang p lang, from_last_dir) :: acc in
        navigation_dir from_d acc d lang

  let navigation p =
    if p.is_dir then invalid_arg "Weberizer.Path.navigation: no filename";
    match p.parent with
    | None -> assert false (* a file must have a parent dir, possibly
                             the base one *)
    | Some d ->
        let fbase, lang, _ = base_lang_ext_of_filename (filename p) in
        let file_nav =
          if fbase = "index" then []
          else [(description_lang p lang, "")] (* "" is the relative link
                                                  to the current file *) in
        navigation_dir "./" file_nav d lang

  let rec last_navigation = function
    | [] -> assert false
    | [(d,_)] -> d
    | _ :: tl -> last_navigation tl

  let description p =
    if p.is_dir then invalid_arg "Weberizer.Path.description: no filename";
    last_navigation (navigation p)

  (*
   * Links for translations
   *)

  (* Use "/" to separate components because they are supported on
     windows and are mandatory for HTML paths *)
  let concat dir file =
    if dir = "" then file
    else if file = "" then dir
    else dir ^ "/" ^ file

  let translations ?(rel_dir=fun _ l -> "../" ^ l) ~langs p =
    let default_lang = match langs with d :: _ -> d | [] -> "" in
    let fbase, lang, ext_p = base_lang_ext_of_filename (filename p) in
    let lang = if lang = "" then default_lang else lang in
    let path_base = Filename.concat (Filename.dirname (full p)) fbase in
    let add_lang l trans =
      let ext = if l = default_lang then ext_p else "." ^ l ^ ext_p in
      if Sys.file_exists(path_base ^ ext) then
        let url =
          if l = lang then ""
          else
            (* Remove "index" if it terminates the path (regardless of
               the extension [ext_p]). *)
            let to_path =
              if end_with fbase "index" then
                concat (from_base p)
                       (String.sub fbase 0 (String.length fbase - 5))
              else (concat (from_base p) fbase) ^ ext_p in
            sprintf "%s%s/%s" (to_base p) (rel_dir lang l) to_path in
        (l, url) :: trans
      else trans in
    List.fold_right add_lang langs []

  (*
   * Recursively browse dirs
   *)

  let concat_dir p dir =
    assert(p.is_dir);
    { name = dir;  is_dir = true;
      full_path = concat p.full_path dir;
      from_base = concat p.from_base dir;
      to_base = "../" ^ p.to_base; (* must end with '/' *)
      parent = Some p;
      desc = [];
    }

  let concat_file p fname =
    if not p.is_dir then failwith "Weberizer.Path.concat_file";
    { name = fname;  is_dir = false;
      full_path = concat p.full_path fname;
      from_base = p.from_base; (* no file *)
      to_base = p.to_base; (* must end with '/' *)
      parent = Some p;
      desc = [];
    }

  let rec iter_files ~filter_dir ~filter_file p f =
    let full_path = full p in
    let files = Sys.readdir full_path in
    for i = 0 to Array.length files - 1 do
      let file = files.(i) in
      if file <> "" (* should not happen *) && file.[0] <> '.' (* hidden *)
      then begin
        if Sys.is_directory (concat full_path file) then
          let p = concat_dir p file in
          (if filter_dir p then iter_files ~filter_dir ~filter_file p f)
        else
          let p = concat_file p file in
          if filter_file p then f p
      end
    done
end

let rec mkdir_if_absent ?(perm=0o750) dir =
  (* default [perm]: group read => web server *)
  if not(Sys.file_exists dir) then begin
    mkdir_if_absent ~perm (Filename.dirname dir);
    Unix.mkdir dir perm
  end

let only_lower = Str.regexp "[a-z]+$"
let check_lang l =
  if not(Str.string_match only_lower l 0) then
    invalid_arg(sprintf "Weberizer.iter_html: language %S not valid" l)

(* [has_allowed_ext fname exts] checks that [fname] ends with one of the
   extension in [exts]. *)
let rec has_allowed_ext fname exts = match exts with
  | [] -> false
  | ext :: tl -> Filename.check_suffix fname ext || has_allowed_ext fname tl

let iter_html ?(langs=["en"]) ?(exts=[".html"]) ?(filter=(fun _ -> true))
              ?perm ?(out_dir=fun x -> x) ?(out_ext=fun x -> x) base f =
  if not(Sys.is_directory base) then
    invalid_arg "Weberizer.iter_html: the base must be a directory";
  match langs with
  | [] -> invalid_arg "Weberizer.iter_html: langs must be <> []"
  | default_lang :: _ ->
      List.iter check_lang langs;
      let filter_dir p = not(List.mem (Path.from_base p) langs)
      and filter_file p = has_allowed_ext (Path.filename p) exts && filter p in
      Path.iter_files ~filter_file ~filter_dir (Path.make base) begin fun p ->
        let fbase, lang, ext =
          Path.base_lang_ext_of_filename (Path.filename p) in
        let lang = if lang = "" then default_lang else lang in
        if List.mem lang langs then begin
          let html = f lang p in
          let dir = Path.concat (out_dir lang) (Path.from_base p) in
          mkdir_if_absent ?perm dir;
          write_html ?perm html (Filename.concat dir (fbase ^ out_ext ext))
        end
      end


let quote_quot_re = Str.regexp_string "\"";;
let arg_to_string (a,v) =
  let v = Str.global_replace quote_quot_re "&quot;" v in
  a ^ "=\"" ^ v ^ "\""

let space_re = Str.regexp "[ \t\n\r]+"
let newline_re = Str.regexp "[\n\r]+"

(* See http://javascript.about.com/library/blnoscript.htm for ideas on
   how to get rid of <noscript>. *)
let email_id = ref 0
let email ?(args=[]) ?content e =
  let at = String.index e '@' in
  let local_part = String.sub e 0 at in
  let at = at + 1 in
  let host_query = String.sub e at (String.length e - at) in
  let host = (try String.sub host_query 0 (String.index host_query '?')
              with Not_found -> host_query) in
  let args = String.concat " " (List.map arg_to_string args) in
  incr email_id;
  let id = Printf.sprintf "ocaml_%i" !email_id in
  let javascript = Printf.sprintf
    "local = %S;\n\
     h = %S;\n\
     hq = %S;\n\
     document.getElementById(%S).innerHTML = \
     '<a href=\"mailto:' + local + '@' + hq + \"\\\" %s>%s<\\/a>\";"
    local_part host (Str.global_replace space_re "%20" host_query) id args
    (match content with
     | None -> "\" + local + '@' + h + \""
     | Some c ->
        let buf = Buffer.create 200 in
        let ch = new Netchannels.output_buffer buf in
        Nethtml.write ch c;
        ch#close_out();
        Str.global_replace newline_re "\\n" (Buffer.contents buf)) in
  let noscript = match content with
    | None -> [Nethtml.Data(local_part);
              Nethtml.Element("abbr", ["title", "(at) &rarr; @"],
                              [Nethtml.Data "(at)"]);
              Nethtml.Data host]
    | Some c -> c @ [Nethtml.Data " &#9001;";
                    Nethtml.Data(local_part);
                    Nethtml.Element("abbr", ["title", "(at) &rarr; @"],
                                    [Nethtml.Data "(at)"]);
                    Nethtml.Data host;
                    Nethtml.Data "&#9002;" ] in
  [Nethtml.Element("span", ["id", id], noscript);
   Nethtml.Element("script", ["type", "text/javascript"],
                   [Nethtml.Data("<!--;\n" ^ javascript ^ "\n//-->") ])]

let is_email (a, e) =
  a = "href"
  && String.length e > 7 && e.[0] = 'm' && e.[1] = 'a' && e.[2] = 'i'
  && e.[3] = 'l' && e.[4] = 't' && e.[5] = 'o' && e.[6] = ':'

(* Concatenate all Data in [l].  If another node is present, raise [Failure]. *)
let concat_content_data l =
  let l = List.map (function
                    | Nethtml.Data s -> s
                    | Nethtml.Element _ -> failwith "concat_content_data") l in
  String.concat "" l

(* Check whether the content of the link is the link mail address. *)
let content_is_email txt email =
  let len_txt = String.length txt in
  is_prefix txt email
  && (len_txt = String.length email || email.[len_txt] = '?')

let rec protect_emails html =
  List.concat(List.map protect_emails_element html)
and protect_emails_element = function
  | Nethtml.Data _ as e -> [e] (* emails in text are not modified *)
  | Nethtml.Element("a", args, content) as e ->
      let emails, args = List.partition is_email args in
      (match emails with
       | [] -> [e]
       | [(_, addr)] ->
           let addr = String.sub addr 7 (String.length addr - 7) in
           let content =
             try
               let txt = concat_content_data content in
               if content_is_email txt addr then None else Some content
             with Failure _ -> None in
           email ~args ?content addr
       | _ -> failwith("Several email addresses not allowed"
                      ^ String.concat ", " (List.map snd emails)))
  | Nethtml.Element(el, args, content) ->
      [Nethtml.Element(el, args, protect_emails content)]

let is_href (a, _) = a = "href"

let apply_relative_href base ((href, url) as arg) =
  try
    let url = parse_url url ~base_syntax:ip_url_syntax in
    (href, string_of_url(Neturl.apply_relative_url base url))
  with Malformed_URL -> arg

let rec apply_relative_url base html =
  List.map (apply_relative_url_element base) html
and apply_relative_url_element base = function
  | Nethtml.Element("a", args, content) ->
      let href, args = List.partition is_href args in
      let href = List.map (apply_relative_href base) href in
      Nethtml.Element("a", href @ args, content)
  | Nethtml.Element(e, args, content) ->
      Nethtml.Element(e, args, apply_relative_url base content)
  | Nethtml.Data _ as e -> e

let relative_url_are_from_base p html =
  let base = make_url ip_url_syntax ~path:(Path.to_base_split p) in
  apply_relative_url base html


(* Caching values
 ***********************************************************************)

module Cache = struct
  module S = Set.Make(String)

  type 'a t = {
    name: string;  (* key to store the value *)
    fname: string; (* filename used for caching on disk *)
    (* FIXME: Maybe a Weak.t is better for [cache] *)
    mutable cache : 'a option; (* cached value (so we do not have to hit
                                 the disk to retrieve it) *)
    mutable update: 'a option -> 'a;
    (* Functions to run to update deps, see [perform_update].  The
       first element is the [name] and is there to prevent circular
       dependencies. *)
    mutable deps: (string * (S.t ref -> unit)) list;
    timeout: float;
    new_if: 'a t -> bool;
    debug: bool;
  }

  let key t = t.name
  let time_last_update fname = (Unix.stat fname).Unix.st_mtime

  (* Touch the filename to record the current time *)
  let touch t =
    let fh = open_out_gen [Open_creat; Open_wronly] 0o644 t.fname in
    close_out fh

  let time t =
    if Sys.file_exists t.fname then time_last_update t.fname
    else neg_infinity

  let update_dependencies t already_updated =
    let exec_dep (key, f) =
      if not(S.mem key !already_updated) then (
        f already_updated; (* supposed to perform a rec update if needed *)
        already_updated := S.add key !already_updated;
      ) in
    List.iter exec_dep t.deps

  let update_and_get ~update t already_updated =
    match t.cache with
    | None ->
       if t.debug then
         eprintf "Weberizer.Cache: %s: no cache, create... %!" t.name;
       update_dependencies t already_updated;
       let x = t.update None in
       if t.debug then prerr_endline "done.";
       t.cache <- Some x;
       touch t;
       x
    | Some x ->
       (* Check if an update is needed. *)
       if update
          || t.timeout <= 0. || time_last_update t.fname +. t.timeout < Unix.time()
          || t.new_if t then (
         if t.debug then
           eprintf "Weberizer.Cache: %s: update value... %!" t.name;
         update_dependencies t already_updated;
         let x_new = t.update t.cache in
         if t.debug then prerr_endline "done.";
         touch t;
         t.cache <- Some x_new;
         x_new
       )
       else (
         if t.debug then eprintf "Weberizer.Cache: %s: use cache %S.\n%!"
                                 t.name t.fname;
         x
       )

  let dep_of t =
    (t.fname, fun updated -> ignore(update_and_get ~update:false t updated))

  let get ?(update=false) t =
    update_and_get ~update t (ref S.empty)

  let default_new_if _ = false (* do not use this to update the cache *)

  let make ?dep ?(new_if=default_new_if) ?(timeout=3600.)
           ?(debug=false)
           name f =
    let base = "weberizer-" ^ Digest.to_hex(Digest.string name) in
    let fname = Filename.concat Filename.temp_dir_name base in
    (* Get the initial value from the file if it is up-to-date *)
    let cache =
      if Sys.file_exists fname && timeout > 0.
         && time_last_update fname +. timeout > Unix.time() then (
        if debug then eprintf "Weberizer.Cache: %s: create from %S.\n"
                              name fname;
        let fh = open_in_bin fname in
        let v = input_value fh in
        close_in fh;
        v (* no "Some" because t.cache is saved *)
      )
      else None in
    let t = { name = name;
              fname = fname;
              cache = cache;
              update = f;
              deps = (match dep with
                      | None -> []
                      | Some t1 -> [dep_of t1]);
              timeout = timeout;
              new_if = new_if;
              debug = debug } in
    (* At exit, cache the current value on disk. *)
    at_exit (fun () ->
             let fh = open_out_bin t.fname in
             output_value fh t.cache;
             close_out fh
            );
    t

  let result ?dep ?new_if ?timeout ?debug name f =
    get(make ?dep ?new_if ?timeout ?debug name f)

  let update ?f t =
    match f with
    | None -> ignore(get t ~update:true)
    | Some f -> t.update <- f;
               ignore(get t ~update:true)

  let depend t ~dep =
    t.deps <- dep_of dep :: t.deps;
    ignore(get t ~update:true)


end
;;
