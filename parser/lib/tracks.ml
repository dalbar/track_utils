module Track_Tokens = struct
  type path_delimiter = Slash | Backshlash

  type delimiter =
    | Slash
    | OpeningCurlyBracket
    | OpeningSquareBracket
    | ClosingCurlyBracket
    | ClosingSquareBracket
    | AuthorTitleDelimiter

  let delimiter_to_string dl =
    match dl with
    | Slash -> "/"
    | OpeningCurlyBracket -> "("
    | ClosingCurlyBracket -> ")"
    | OpeningSquareBracket -> "["
    | ClosingSquareBracket -> "["
    | AuthorTitleDelimiter -> "-"

  type prefix = Vinyl

  let prefix_to_string p = match p with Vinyl -> "v"

  type feature_operator = Feature | Ft | And

  let feature_operator_to_string op =
    match op with Feature -> "feature" | Ft -> "ft" | And -> "&"

  type operator = Dot | Feature of feature_operator

  let operator_to_string op =
    match op with
    | Dot -> "."
    | Feature ft_op -> feature_operator_to_string ft_op

  type track_token =
    | Operator of operator
    | Word of string
    | Prefix of prefix
    | Delimiter of delimiter

  let flush_buffer buffer =
    let content = Buffer.contents buffer in
    Buffer.clear buffer ; content

  let cons_non_empty_buffer_as_word buffer tokens =
    let tmp_acc =
      if Buffer.length buffer = 0 then tokens
      else Word (flush_buffer buffer) :: tokens
    in
    tmp_acc

  let buffer_prev_element buffer position = Buffer.nth buffer (position - 1)

  let buffer_next_element buffer position = Buffer.nth buffer (position + 1)

  let token_to_string token =
    match token with
    | Operator o -> operator_to_string o
    | Word word -> word
    | Prefix p -> prefix_to_string p
    | Delimiter d -> delimiter_to_string d

  let track_tokenizer track_buffer =
    let buffer_len = Buffer.length track_buffer in
    let tmp_buffer = Buffer.create buffer_len in
    Buffer.add_string tmp_buffer (Buffer.contents track_buffer) ;
    Buffer.add_char tmp_buffer '\n' ;
    let rec loop tracks tokens word_acc cur_position =
      try
        let cur_char = Buffer.nth tmp_buffer cur_position in
        let next_word_acc = word_acc ^ Char.escaped cur_char in
        let cur_tokens = Word word_acc :: tokens in
        match cur_char with
        | 'v' ->
            if buffer_next_element tmp_buffer cur_position = '_' then
              loop tracks (Prefix Vinyl :: tokens) "" (cur_position + 2)
            else loop tracks tokens next_word_acc (cur_position + 1)
        | '(' ->
            loop tracks
              (Delimiter OpeningCurlyBracket :: cur_tokens)
              "" (cur_position + 1)
        | '[' ->
            loop tracks
              (Delimiter OpeningCurlyBracket :: cur_tokens)
              "" (cur_position + 1)
        | ')' ->
            loop tracks
              (Delimiter ClosingCurlyBracket :: cur_tokens)
              "" (cur_position + 1)
        | ']' ->
            loop tracks
              (Delimiter ClosingSquareBracket :: cur_tokens)
              "" (cur_position + 1)
        | '/' ->
            loop tracks (Delimiter Slash :: cur_tokens) "" (cur_position + 1)
        | ' ' ->
            if
              buffer_next_element tmp_buffer cur_position = '-'
              && buffer_next_element tmp_buffer (cur_position + 1) = ' '
            then
              loop tracks
                (Delimiter AuthorTitleDelimiter :: cur_tokens)
                "" (cur_position + 3)
            else loop tracks cur_tokens "" (cur_position + 1)
        | '.' -> loop tracks (Operator Dot :: cur_tokens) "" (cur_position + 1)
        | '\n' -> loop (List.rev cur_tokens :: tracks) [] "" (cur_position + 1)
        | _ -> loop tracks tokens next_word_acc (cur_position + 1)
      with Invalid_argument _ -> tracks
    in
    match Buffer.length tmp_buffer with 1 -> [] | _ -> loop [] [] "" 0

  let track_tokenizer_string track_string =
    let in_buffer = Buffer.create (String.length track_string * 2) in
    Buffer.add_string in_buffer track_string ;
    track_tokenizer in_buffer
end

module Track_Table = struct
  type extensions = WAV | MP3 | MP4

  let inital_key_values =
    [ ("author", "")
    ; ("feature_operator", "")
    ; ("features", "")
    ; ("vinyl", "no")
    ; ("title", "")
    ; ("title_plus", "")
    ; ("version", "")
    ; ("version_plus", "")
    ; ("extensions", "")
    ; ("year", "")
    ; ("misc", "") ]

  let empty () = CCHashtbl.Poly.of_list inital_key_values
end

open Track_Tokens

type track_record_field =
  | Word of string
  | Vinyl of bool
  | Words of string list

type track_record =
  { year: string
  ; vinyl: bool
  ; author: string
  ; feature_operator: string
  ; features: string
  ; title: string
  ; title_plus: string list
  ; version: string
  ; version_plus: string list
  ; extension: string }

type record_mapping = string * track_record

type track_block = Year | AuthorAndPrefix | Title | Version | Extension

type property_difference = {key: string; diff: string * string}

let empty =
  { year= ""
  ; vinyl= false
  ; author= ""
  ; feature_operator= ""
  ; features= ""
  ; title= ""
  ; title_plus= []
  ; version= ""
  ; version_plus= []
  ; extension= "" }

let track_record_field_to_string field =
  match field with
  | Word w -> w
  | Words w -> String.concat ";" w
  | Vinyl b -> if b then "vinyl" else "not vinyl"

let key_to_field r key =
  match key with
  | "year" -> Word r.year
  | "vinyl" -> Vinyl r.vinyl
  | "author" -> Word r.author
  | "feature_operator" -> Word r.feature_operator
  | "features" -> Word r.features
  | "title" -> Word r.title
  | "title_plus" -> Words r.title_plus
  | "version" -> Word r.version
  | "version_plus" -> Words r.version_plus
  | "extension" -> Word r.extension
  | _ -> Word ""

let differences_record r1 r2 =
  let field_r1 key = key_to_field r1 key in
  let field_r2 key = key_to_field r2 key in
  let keys =
    [ "year"
    ; "vinyl"
    ; "author"
    ; "feature_operator"
    ; "features"
    ; "title"
    ; "title_plus"
    ; "vesion"
    ; "version_plus"
    ; "extension" ]
  in
  let paired_field =
    List.map
      (fun key ->
        { key
        ; diff=
            ( field_r1 key |> track_record_field_to_string
            , field_r2 key |> track_record_field_to_string ) } )
      keys
  in
  List.filter (fun {diff= f1, f2; _} -> f1 <> f2) paired_field

let year_regexp = Re.Perl.compile (Re.Perl.re "^[1-9][0-9]{3}$")

let parse_track_tokens_to_hashtbl tokens =
  let track_table = Track_Table.empty () in
  let inc_bracket_depth depth = depth + 1 in
  let dec_bracket_depth depth = depth - 1 in
  let rec loop tokens word_acc bracket_depth track_block =
    let cur_info = String.concat " " word_acc in
    match (tokens, track_block) with
    | [], AuthorAndPrefix -> Hashtbl.replace track_table "author" cur_info
    | [], Year ->
        let years_list = Re.matches year_regexp cur_info in
        if List.length years_list > 0 then
          Hashtbl.replace track_table "year" cur_info
        else if Hashtbl.find track_table "misc" = "" then
          Hashtbl.replace track_table "misc" cur_info
        else Hashtbl.add track_table "misc" cur_info
    | [], _ -> ()
    | Operator Dot :: rest, Extension ->
        Hashtbl.replace track_table "extension" cur_info ;
        loop rest [] bracket_depth Version
    | Operator Dot :: rest, Version ->
        let years_list = Re.matches year_regexp cur_info in
        if List.length years_list > 0 then
          Hashtbl.replace track_table "year" cur_info
        else if Hashtbl.find track_table "misc" = "" then
          Hashtbl.add track_table "misc" cur_info
        else Hashtbl.replace track_table "misc" cur_info ;
        loop rest [] bracket_depth track_block
    | Operator _ :: rest, _ -> loop rest word_acc bracket_depth track_block
    | Prefix Vinyl :: rest, _ ->
        Hashtbl.replace track_table "author" cur_info ;
        Hashtbl.replace track_table "vinyl" "yes" ;
        loop rest [] bracket_depth Year
    | Delimiter Slash :: rest, AuthorAndPrefix ->
        Hashtbl.replace track_table "author" cur_info ;
        loop rest [] bracket_depth Year
    | Delimiter AuthorTitleDelimiter :: rest, _ ->
        Hashtbl.replace track_table "title" cur_info ;
        loop rest [] 0 AuthorAndPrefix
    | ( (Delimiter ClosingCurlyBracket | Delimiter ClosingSquareBracket) :: rest
      , Extension ) ->
        loop rest [] (inc_bracket_depth bracket_depth) Version
    | Delimiter (ClosingCurlyBracket | ClosingSquareBracket) :: rest, Title ->
        let new_depth = inc_bracket_depth bracket_depth in
        if new_depth > 1 then
          let bracket = Track_Tokens.token_to_string (List.nth tokens 0) in
          loop rest (bracket :: word_acc)
            (inc_bracket_depth bracket_depth)
            Title
        else loop rest [] (inc_bracket_depth bracket_depth) track_block
    | Delimiter (ClosingCurlyBracket | ClosingSquareBracket) :: rest, Version
      ->
        let new_depth = inc_bracket_depth bracket_depth in
        if new_depth > 2 then
          let bracket = Track_Tokens.token_to_string (List.nth tokens 0) in
          loop rest (bracket :: word_acc)
            (inc_bracket_depth bracket_depth)
            Version
        else loop rest [] (inc_bracket_depth bracket_depth) track_block
    | Delimiter (OpeningCurlyBracket | OpeningSquareBracket) :: rest, Version
      ->
        let new_depth = dec_bracket_depth bracket_depth in
        if new_depth = 0 then (
          Hashtbl.replace track_table "version" cur_info ;
          loop rest [] new_depth Title )
        else if new_depth = 1 then (
          if Hashtbl.find track_table "version_plus" = "" then
            Hashtbl.replace track_table "version_plus" cur_info
          else Hashtbl.add track_table "version_plus" cur_info ;
          loop rest [] new_depth Version )
        else
          let bracket = Track_Tokens.token_to_string (List.nth tokens 0) in
          loop rest (bracket :: word_acc) new_depth Version
    | Delimiter (OpeningCurlyBracket | OpeningSquareBracket) :: rest, Title ->
        let new_depth = dec_bracket_depth bracket_depth in
        if new_depth = 0 then (
          Hashtbl.replace track_table "title_plus" cur_info ;
          loop rest [] new_depth Title )
        else
          let bracket = Track_Tokens.token_to_string (List.nth tokens 0) in
          loop rest (bracket :: word_acc) new_depth Title
    | Word ("feature" | "feat" | "ft" | "with") :: rest, AuthorAndPrefix ->
        let op = List.hd tokens in
        Hashtbl.replace track_table "feature_operator" @@ token_to_string op ;
        Hashtbl.replace track_table "features" cur_info ;
        loop rest [] bracket_depth AuthorAndPrefix
    | Word w :: rest, _ -> loop rest (w :: word_acc) bracket_depth track_block
    | Delimiter _ :: rest, _ -> loop rest word_acc bracket_depth track_block
  in
  let reserved_tokens = List.rev tokens in
  loop reserved_tokens [] 0 Extension ;
  track_table

let token_hashtbl_to_token_record hashtbl =
  let find key = Hashtbl.find hashtbl key in
  let find_all key = Hashtbl.find_all hashtbl key in
  { year= find "year"
  ; vinyl= find "vinyl" = "yes"
  ; author= find "author"
  ; feature_operator= find "feature_operator"
  ; features= find "features"
  ; title= find "title"
  ; title_plus= find_all "title_plus"
  ; version= find "version"
  ; version_plus= find_all "version_plus"
  ; extension= find "extension" }

let parse_track_tokens tokens =
  token_hashtbl_to_token_record @@ parse_track_tokens_to_hashtbl tokens

let parse_track_tokens_list token_list =
  List.map
    (fun entry ->
      token_hashtbl_to_token_record @@ parse_track_tokens_to_hashtbl entry )
    token_list

let token_list_to_string list =
  let token_to_string = Track_Tokens.token_to_string in
  let string_list = List.map token_to_string list in
  String.concat ";" string_list

let stringify_token_record track =
  let concat_list_with_bracets list =
    List.fold_left (fun acc cur -> acc ^ "(" ^ cur ^ ") ") "" list
  in
  let vinyl = if track.vinyl then "v_" else "" in
  let version_plus =
    if not @@ List.mem "" track.version_plus then
      concat_list_with_bracets track.version_plus
    else ""
  in
  let version =
    if track.version <> "" then "(" ^ track.version ^ version_plus ^ ")"
    else ""
  in
  let title_plus =
    if not @@ List.mem "" track.title_plus then
      concat_list_with_bracets track.title_plus
    else ""
  in
  let year = if track.year <> "" then track.year ^ "/" else "" in
  let author_delimiter = " - " in
  let extension = "." ^ track.extension in
  let features =
    if track.features <> "" then
      " " ^ track.feature_operator ^ " " ^ track.features
    else ""
  in
  year ^ vinyl ^ track.author ^ features ^ author_delimiter ^ track.title
  ^ title_plus ^ version ^ extension

let parse_string_list list =
  let tracks = String.concat "\n" list in
  parse_track_tokens_list @@ Track_Tokens.track_tokenizer_string tracks
