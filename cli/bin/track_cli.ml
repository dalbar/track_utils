open Track_utils_shortener
open Track_utils_parser
open Track_utils_helpers.Io
open Track_utils_helpers.Ds
open Track_utils_parser.Tracks

let shortening_processing_pipe track_records concat_path1 =
  let track_shortened_map = Shortener.shorten_track_list track_records in
  let mapping_shortened_record = CCHashtbl.to_list track_shortened_map in
  let mapping_shortened_old =
    List.map
      (fun (key, record) -> (key, Tracks.stringify_token_record record))
      mapping_shortened_record
  in
  if List.length mapping_shortened_old > 0 then (
    perist_key_record_mapping mapping_shortened_old
    @@ concat_path1 ".track_utils" ;
    List.iter
      (fun (shortened, old) ->
        if Sys.file_exists (concat_path1 old) then
          Sys.rename (concat_path1 old) (concat_path1 shortened) )
      mapping_shortened_old ) ;
  mapping_shortened_record

let org_processing_pipe history_pairs mapping dest =
  if List.length mapping > 0 then (
    let history_tbl = History.get_hist_tbl history_pairs ~inv:true in
    let to_key (_, r) = (r.vinyl, r.extension, r.year) in
    let org_content = CCOpt.wrap read_file_to_string dest in
    let org_ds = CCOpt.get_or ~default:"" org_content |> Org.parse in
    let differences_org_to_mapping = Org.mapping_differences org_ds mapping history_tbl in
    Org.print_warning differences_org_to_mapping dest ;
    let differences_mapping_to_org = Org.mapping_differences mapping org_ds history_tbl in
    let fixed_missing_files = org_ds @ differences_mapping_to_org.file in
    let fixed_shortened_dup = List.filter (fun (name, _) -> List.mem name differences_org_to_mapping.delete |> (=) false ) fixed_missing_files in
    let updated_records =
      Org.patch_mapping fixed_shortened_dup
        differences_mapping_to_org.properties
    in
    let grouped = group_by to_key updated_records in
    write_org_file grouped dest )

let history_processing_pipe files concat_cur_path =
  let dest = concat_cur_path ".track_utils" in
  if Sys.file_exists dest then
    let history = read_file_to_string dest in
    let hist_tbl = History.parse history in
    List.map
      (fun file ->
        if Hashtbl.mem hist_tbl file then
          Hashtbl.find hist_tbl file
        else file )
      files
  else files

let reverting_processing_pipe history_pairs path =
  let to_key (_, r) = (r.vinyl, r.extension) in
  let history_file = concat_path path ".track_utils" in
  let org_file = concat_path path "db.org" in
  if Sys.file_exists history_file then (
    List.iter
      (fun (shortened, long) -> Sys.rename shortened long)
      history_pairs ;
    Sys.remove history_file ) ;
  if Sys.file_exists org_file then
    let org_content = CCOpt.wrap read_file_to_string org_file in
    let org_ds = CCOpt.get_or ~default:"" org_content |> Org.parse in
    let grouped = group_by to_key (Org.revert_mapping org_ds history_pairs) in
    write_org_file grouped org_file

let nml_processing_pipe history_pairs mapping path files =
  let history_tbl = History.get_hist_tbl ~inv:true history_pairs in
  let nml_files =
    List.filter (fun name -> Filename.extension name = ".nml") files
  in
  let patch name = Nml.patch_nml history_tbl mapping path name in
  List.iter patch nml_files

let track_cli revert recurisve shorten org nml path =
  let rec loop cur_path dic_acc =
    let concat_cur_path file = concat_path cur_path file in
    let cur_files = Sys.readdir cur_path in
    let {directories; files } = extract_dirs_and_track_files cur_path cur_files in
    let reverted_files = history_processing_pipe files concat_cur_path in
    let history_pairs =
      List.map2
        (fun shortened reverted -> (shortened, reverted))
        files reverted_files
      |> List.filter (fun (shortened, reverted) -> shortened <> reverted)
    in
    if revert then reverting_processing_pipe history_pairs cur_path ;
    let track_records = Tracks.parse_string_list reverted_files in
    let record_map =
      if shorten then shortening_processing_pipe track_records concat_cur_path
      else
        List.map2
          (fun record files -> (Filename.basename files, record))
          (List.rev track_records) files
    in
    if org then org_processing_pipe history_pairs record_map (concat_cur_path "db.org") ;
    if nml then nml_processing_pipe history_pairs record_map cur_path files ;
    if recurisve then
      match directories @ dic_acc with [] -> () | hd :: rest -> loop hd rest
  in
  loop path []

open Cmdliner

let path = Arg.(value & pos 0 string "." & info [] ~docv:"PATH")

let shorten =
  Arg.(
    value & flag
    & info ["s"; "shorten"] ~docv:"N"
        ~doc:"Shorten all files in the target directory")

let org =
  Arg.(
    value & flag
    & info ["t"; "org"] ~docv:"t" ~doc:"Create Org File of all Tracks")

let recursive =
  let doc = "Execute operations recursively." in
  Arg.(value & flag & info ["r"; "R"; "recursive"] ~doc)

let revert =
  let doc = "Undo shortening operations." in
  Arg.(value & flag & info ["u"] ~doc)

let nml =
  Arg.(
    value & flag
    & info ["v"; "nml"] ~docv:"v" ~doc:"Patch NML File with org file")

let cmd =
  ( Term.(const track_cli $ revert $ recursive $ shorten $ org $ nml $ path)
  , Term.info "track-utils" )

let () = Term.(exit @@ eval cmd)
