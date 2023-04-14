open Core

type position = {
    line: int;
    character: int;
}

type range = {
    start: position;
    end_l: position;
}

type location = {
    uri: string;
    range: range;
}

type textDocumentIdentifier = {
    uri: string;
    languageId: string;
}

let position_to_json (p: position) : Yojson.Basic.json =
    `Assoc [
        ("line", `Int p.line);
        ("character", `Int p.character);
    ]

let range_to_json (r: range) : Yojson.Basic.json =
    `Assoc [
        ("start", position_to_json r.start);
        ("end", position_to_json r.end_l);
    ]

let location_to_json (l: location) : Yojson.Basic.json =
    `Assoc [
        ("uri", `String l.uri);
        ("range", range_to_json l.range);
    ]

let textDocumentIdentifier_to_json (t: textDocumentIdentifier) : Yojson.Basic.json =
    `Assoc [
        ("uri", `String t.uri);
        ("languageId", `String t.languageId);
    ]

let json_rpc_req_format = "Content-Length: {json_string_len}\r\n\r\n{json_string}"
let json_rpc_res_regex = "Content-Length: \\([0-9]*\\)\r"
let result_regex = "Name full_name='\\([a-zA-Z0-9_.]*\\)'"

let language_server_path = match (Sys.getenv "JEDI_LANGUAGE_SERVER_PATH") with
    | None -> "/Users/drramos/Library/Caches/pypoetry/virtualenvs/jedi-language-server-NRMF7l2B-py3.10/bin/jedi-language-server"
    | Some path -> path

let language_server_options = match (Sys.getenv "JEDI_LANGUAGE_SERVER_OPTIONS") with
    | None -> "/Users/drramos/Documents/comby/jedi-language-server/opt.json"
    | Some options -> options

let language_server_capabilities = match (Sys.getenv "JEDI_LANGUAGE_SERVER_CAPABILITIES") with
    | None -> "/Users/drramos/Documents/comby/jedi-language-server/cap.json"
    | Some capabilities -> capabilities

let add_key_v dict key v = 
    match dict with
    | `Assoc lst -> `Assoc (lst @ [(key, v)])
    | _ -> failwith "Not an assoc list"


let send_message method_name id params =
    let message_dict = [("jsonrpc", `String "2.0"); 
                        ("id", `Int id); 
                        ("method", `String method_name); 
                        ("params", params); ] in
    Yojson.Basic.to_string (`Assoc message_dict)


let format_message str = (json_rpc_req_format |> 
                            Str.global_replace (Str.regexp "{json_string_len}") (string_of_int (String.length str)) |> 
                            Str.global_replace (Str.regexp "{json_string}") str)


let gen_params rootUri options = `Assoc [("rootPath", `Null); 
                                        ("rootUri", `String rootUri); 
                                        ("initializationOptions", options); 
                                        ("trace", `String "off"); 
                                        ("workspaceFolders", `Null); 
                                        ]

let send_to_lsp pin pout msg =

    let _ = output_string pout msg in (* send to lsp *)
    let _ = flush pout in 
    let line = input_line pin in (* read content length*)
    let _ = input_line pin in (* read dummy line *)

    let _ = Str.search_forward (Str.regexp json_rpc_res_regex) line 0 in
    let size = Str.matched_group 1 line in (* length of the message *)
    let bt : bytes = Bytes.create (int_of_string size + 2) in
    let _ = In_channel.input pin ~buf:bt ~pos:0 ~len:(int_of_string size + 2) in
    (Bytes.to_string bt)



let initialize pin pout rootUri options capabilities = 
    let params = add_key_v (gen_params rootUri options) "capabilities" capabilities in 
    let msg = send_message "initialize" 0 params in
    send_to_lsp pin pout (format_message msg)


let procs = ref None

let terminate_subprocess () =
    match !procs with
    | Some (pin, pout) ->
        let _ = Unix.close_process (pin, pout) in
        procs := None
    | None -> ()

let infer_var_type src_uri filepath l c = 
    
    (*let _ = print_endline "testing" in
    let _ = print_endline (string_of_int (l+1)) in
    let _ = print_endline (string_of_int (c-1)) in*)

    let get_procs ps = 
        match !ps with 
        | Some(pin,pout) ->
            pin, pout
        | None -> begin
            let (pin, pout) : in_channel * out_channel = Unix.open_process language_server_path  in 
            let options :Yojson.Basic.t = Yojson.Basic.from_file language_server_options in 
            let capabilities :Yojson.Basic.t = Yojson.Basic.from_file language_server_capabilities in 
            let () = at_exit terminate_subprocess in 
            let _ = initialize pin pout src_uri options capabilities in 
            procs := ( Some(pin,pout) );
            pin, pout
        end
    in 

    let pin, pout = get_procs procs in
    let doc_id : textDocumentIdentifier =  {uri = filepath; languageId = "python"} in 
    let position : position = {line = l+1; character = c} in 
    let params = `Assoc [("textDocument", textDocumentIdentifier_to_json doc_id); 
                        ("position", position_to_json position); 
                        ("context", `Assoc [("includeDeclaration", `Bool true)])] in 
    let request = send_message "textDocument/hover" 1 params in 

    let response = (send_to_lsp pin pout (format_message request)) in
    let json_res = Yojson.Basic.from_string response in
    let result = json_res |> Yojson.Basic.Util.member "result" in 
    if result != `Null then
        let contents = result |> Yojson.Basic.Util.member "contents" in
        let value = contents |> Yojson.Basic.Util.member "value" in
        let value_str = Yojson.Basic.Util.to_string value in
        let _ = Str.search_forward (Str.regexp result_regex) value_str 0 in
        let ret_val = Str.matched_group 1 value_str in 
        Some ret_val
    else
        None