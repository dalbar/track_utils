open Format
open Tracks
open Re

type properties =
  {index: int; merged: record_mapping; differences: property_difference list}

type mapping_diff = {file: record_mapping list; properties: properties list; delete: string list}

let print_warning {file; properties; _} dest =
  let file_errors = List.length file in
  let properties_errors = List.length properties in
  printf "@.%d problems were found for %s@."
    (file_errors + properties_errors)
    dest ;
  if file_errors > 0 then
    printf "The following files are not existing in the current directory@." ;
  List.iter (fun (name, _) -> printf "- %s@." name) file ;
  if properties_errors > 0 then (
    printf "@." ;
    printf "The following titles have invalid properties@." ;
    List.iter
      (fun {merged= name, _; differences; _} ->
        printf "@." ;
        printf "title:    %s@." name ;
        List.iter
          (fun {key; diff= v1, v2} ->
            printf "property: %s@." key ;
            printf "expected: %s@." v2 ;
            printf "actual:   %s@." v1 )
          differences )
      properties )

let print_property_string ppf key value =
  fprintf ppf "@[<h>%s%s%s@[<h 2>%s@]@]@." ":" key ":    " value

let print_property_string_list ppf key values =
  let value = String.concat "; " values in
  print_property_string ppf key value

let print_header ppf mapping  =
  let _, props = mapping in
  let year = props.year in
  let extension = String.uppercase_ascii props.extension in
  match props with
  | {vinyl= true; _} ->
      Format.fprintf ppf "* Year %s: %s Files with VINYL@." year extension
  | {vinyl= false; _} ->
      Format.fprintf ppf "* Year %s: %s Files without VINYL@." year extension

let print_title ppf title = fprintf ppf "@[<h>%s%s@]@." "** " title

let print_record ppf title record =
  let p f = f ppf in
  p print_title title ;
  fprintf ppf ":PROPERTIES:@." ;
  p print_property_string "Author" record.author ;
  p print_property_string "Author+" record.features ;
  p print_property_string "Title" record.title ;
  p print_property_string_list "Title+" record.title_plus ;
  p print_property_string "Version" record.version ;
  p print_property_string_list "Version+" record.version_plus ;
  fprintf ppf ":END:@."

let print_group ppf group =
  print_header ppf @@ List.nth group 0;
  List.iter (fun (title, record) -> print_record ppf title record) group

let print_groups ppf groups =
  List.iter (fun group -> print_group ppf group) groups

let filter_properties_tag raw =
  List.filter (fun entry -> entry <> ":PROPERTIES:") raw

let remove_tag raw =
  let tag = Re.Perl.re ":(.*):    " |> Re.Perl.compile in
  let delim = Re.Perl.re ";" |> Re.Perl.compile in
  let values = Re.split tag raw in
  if List.length values = 0 then [""] else List.nth values 0 |> Re.split delim

let parse_entry entry =
  let name =
    List.nth entry 0 |> fun raw -> String.sub raw 3 (String.length raw - 3)
  in
  let nth_property n = List.nth entry n |> remove_tag in
  let plain_property n = List.nth (nth_property n) 0 in
  let empty_record = Tracks.empty in
  ( name
  , { empty_record with
      author= plain_property 1
    ; features= plain_property 2
    ; title= plain_property 3
    ; title_plus= nth_property 4
    ; version= plain_property 5
    ; version_plus= nth_property 6 } )

let parse_group headers group =
  let year, extension, vinyl = headers in
  let update_with_header (name, record) =
    (name, {record with extension; vinyl; year})
  in
  let entry_delim = Perl.re ":END:\n" |> Perl.compile in
  let property_delim = Perl.re "\n" |> Perl.compile in
  split entry_delim group
  |> List.map (fun entry ->
         split property_delim entry |> filter_properties_tag |> parse_entry
         |> update_with_header )

let extract_headers raw =
  let text_to_vinyl text = match text with "with" -> true | _ -> false in
  let header_regexp = Perl.re "\\* Year (.*): (.*) Files (.*) VINYL" |> Perl.compile in
  let occurrences = Re.all header_regexp raw in
  List.map
    (fun substrings ->
      match Group.all substrings with
      | [| _ ; year ; ftype; vinyl |] ->
          (year, String.lowercase_ascii ftype, text_to_vinyl vinyl)
      | _ -> ("0000", "UNKNOWN", false) )
    occurrences

let parse content =
  let headers = extract_headers content in
  let header_delim =
    Perl.re "\\* Year (.*): (.*) Files (.*) VINYL" |> Perl.compile
  in
  let groups = Re.split header_delim content in
  List.map2 (fun header group -> parse_group header group) headers groups
  |> List.flatten

let mapping_differences m1 m2 hist_tbl =
  let tbl2 = CCHashtbl.of_list m2 in
  let get_shortened_name name  = CCHashtbl.get_or hist_tbl name ~default:name in
  let rec loop differences entries i =
    match entries with
    | (name, record) :: rest ->
        let name_with_year = (Format.sprintf "%s/%s" record.year name) in
        let shortened = get_shortened_name name_with_year in
        if shortened <> name_with_year then (
            { differences with 
              delete = (name :: differences.delete )} 
        )
        else if Hashtbl.mem tbl2 name then
          let r2 = Hashtbl.find tbl2 name in
          let property_differences =
            differences_record record r2
            |> List.filter (fun {key; _} -> key <> "feature_operator")
          in
          if List.length property_differences > 0 then
            let properties_entry =
              { index= i
              ; merged= (name, record)
              ; differences= property_differences }
            in
            loop
              { differences with
                properties= properties_entry :: differences.properties }
              rest (i + 1)
          else loop differences rest (i + 1)
        else
          loop
            {differences with file= (name, record) :: differences.file}
            rest (i + 1)
    | _ -> differences
  in
  loop {file= []; properties= []; delete = []} m1 0

let patch_mapping mapping properties =
  let rec loop cur_mapping to_patch =
    match to_patch with
    | {index; merged; _} :: rest ->
        loop (CCList.set_at_idx index merged cur_mapping) rest
    | [] -> cur_mapping
  in
  loop mapping properties

let revert_mapping mapping history =
  let find_in_history name =
    CCList.find_opt
      (fun (shortened, _) -> name = Filename.basename shortened)
      history
  in
  List.map
    (fun (name, record) ->
      find_in_history name
      |> CCOpt.get_or ~default:(name, name)
      |> fun (_, reverted) -> (Filename.basename reverted, record) )
    mapping
