package main

import "core:fmt"
import "core:path/filepath"
import "core:os"
import "core:strings"
import "core:c"
import "core:mem"
import "core:bytes"
import "core:slice"

foreign import parser "clib/tree-sitter-kotlin/parser.a"
foreign import ts "clib/tree-sitter-kotlin/libtree-sitter.a"

Parser :: rawptr;
Language :: rawptr;
Tree :: rawptr;
Query :: rawptr;
QueryCursor :: rawptr;

QueryError :: u8;

Node :: struct {
  ctx: [4]u32,
  id: rawptr,
  tree: Tree,
};

Point :: struct {
  row: u32,
  column: u32
}

QueryCapture :: struct {
  node: Node,
  index: u32
}

QueryMatch :: struct {
  id: u32,
  pattern_index: u16,
  capture_count: u16,
  captures: [^]QueryCapture,
}

InputEdit :: struct {
  start_byte: u32,
  old_end_byte: u32,
  new_end_byte: u32,
  start_point: Point,
  old_end_point: Point,
  new_end_point: Point,
}

@(link_prefix = "ts_")
foreign ts {
  parser_new :: proc() -> Parser ---;
  parser_set_language :: proc(parser: Parser, language: Language) ---;
  parser_parse_string :: proc(parser: Parser, tree: Tree, source: cstring, source_len: u32) -> Tree ---;
  tree_print_dot_graph :: proc(tree: Tree, file: c.int) ---;
  tree_root_node :: proc(tree: Tree) -> Node ---;
  tree_edit :: proc (tree: Tree, edit: ^InputEdit) ---;
  node_string :: proc(root_node: Node) -> cstring ---;
  node_start_byte :: proc(node: Node) -> u32 ---;
  node_end_byte :: proc(node: Node) -> u32 ---;
  node_start_point :: proc (node: Node) -> Point ---;
  node_end_point :: proc (node: Node) -> Point ---;
  query_new :: proc(language: Language, source: cstring, source_len: u32, error_offset: ^u32, error_type: ^QueryError) -> Query ---;
  query_cursor_new :: proc() -> QueryCursor ---;
  query_cursor_delete :: proc(cursor: QueryCursor) ---;
  query_cursor_exec :: proc(cursor: QueryCursor, query: Query, node: Node) ---;
  query_cursor_next_match :: proc(cursor: QueryCursor, match: ^QueryMatch) -> bool ---;
}

foreign parser {
  tree_sitter_kotlin :: proc() -> Language ---;
}

Process_Kotlin_File_Error :: enum {
  Parse_Failed = 1
}

language := tree_sitter_kotlin()

process_kotlin_file :: proc(parser: ^Parser, filepath: string) -> (err: Process_Kotlin_File_Error) {
  // source, ok := os.read_entire_file_from_filename(filepath)
  // if !ok {
  //   return .Parse_Failed
  // }
  // tree := parser_parse_string(parser^, nil, cstring(raw_data(source)), u32(len(source)))
  // root_node := tree_root_node(tree)
  // fmt.eprintf("Source tree of %s:\n%s\n\n", filepath, node_string(root_node))
  return nil
}

Remove_Wiring_Error :: enum {
  None,
  PresenterParseFailed,
  WiringParseFailed
}

remove_wiring_from_presenter :: proc(parser: ^Parser, presenter_filepath: string, wiring_filepath: string) -> (err: Remove_Wiring_Error) {
  presenter_source : []u8
  wiring_source : []u8
  ok : bool
  presenter_source, ok = os.read_entire_file_from_filename(presenter_filepath)
  if !ok {
    return .PresenterParseFailed
  }
  presenter_tree := parser_parse_string(parser^, nil, cstring(raw_data(presenter_source)), u32(len(presenter_source)))
  wiring_source, ok = os.read_entire_file_from_filename(wiring_filepath)
  if !ok {
    return .WiringParseFailed
  }
  wiring_tree := parser_parse_string(parser^, nil, cstring(raw_data(wiring_source)), u32(len(wiring_source)))

  wiring_calls_query_source := `
(call_expression
  (navigation_expression
   (simple_identifier) @nav_id
   (navigation_suffix (simple_identifier) @method)
  )
  (call_suffix (value_arguments) @args)
) @call_expr
`
  method_body_query_source := `
(function_declaration
 (simple_identifier) @name
   (function_value_parameters) @params
   (function_body (_) @body)
 ) @body_expr
`
  error_offset : u32
  error_type : QueryError

  cursor := query_cursor_new()
  defer query_cursor_delete(cursor)
  method_body_cursor := query_cursor_new()
  defer query_cursor_delete(method_body_cursor)

  method_calls_query := query_new(
    language,
    cstring(raw_data(wiring_calls_query_source)),
    u32(len(wiring_calls_query_source)),
    &error_offset,
    &error_type
  )
  query_cursor_exec(cursor, method_calls_query, tree_root_node(presenter_tree))

  method_body_query := query_new(
    language,
    cstring(raw_data(method_body_query_source)),
    u32(len(method_body_query_source)),
    &error_offset,
    &error_type
  )

  presenter_query_match : QueryMatch
  method_body_query_match : QueryMatch

  editable_presenter_source : [dynamic]u8
  replaced := false
  for (query_cursor_next_match(cursor, &presenter_query_match)) {
    if len(editable_presenter_source) == 0 {
      resize(&editable_presenter_source, len(presenter_source))
      copy(editable_presenter_source[:], presenter_source[:])
    }

    assert(presenter_query_match.capture_count == 4)
    object := source_text(capture_by_index(presenter_query_match, 0), editable_presenter_source[:])
    if string(object) == "wiring" {
      method := source_text(capture_by_index(presenter_query_match, 1), editable_presenter_source[:])
      args := source_text(capture_by_index(presenter_query_match, 2), editable_presenter_source[:])

      query_cursor_exec(method_body_cursor, method_body_query, tree_root_node(wiring_tree))
      for (query_cursor_next_match(method_body_cursor, &method_body_query_match)) {
        assert(method_body_query_match.capture_count == 4)
        name := source_text(capture_by_index(method_body_query_match, 0), wiring_source)
        if mem.compare(name, method) == 0 {
          wiring_call_capture := capture_by_index(presenter_query_match, 3)
          wiring_fun_body_source := source_text(capture_by_index(method_body_query_match, 2), wiring_source)

          insert_source : []u8
          insert_node : Node
          if (string(args) != "()") {
            call_args_fmt, _ := strings.replace_all(string(args), "\n", " ")
            fun_args := source_text(capture_by_index(method_body_query_match, 1), wiring_source)
            fun_args_fmt, _  := strings.replace_all(string(fun_args), "\n", " ")
            padding := make([]u8, node_start_point(wiring_call_capture.node).column)
            slice.fill(padding, ' ')
            insert_source = transmute([]u8)fmt.aprintf("// noship wiring call with args:\n%s// call_args:  %s\n%s// fun_params: %s\n%s%s", padding, call_args_fmt, padding, fun_args_fmt, padding, wiring_fun_body_source)
            insert_node = tree_root_node(parser_parse_string(parser^, nil, cstring(raw_data(insert_source)), u32(len(insert_source))))
          } else {
            insert_source = wiring_fun_body_source
            insert_node = capture_by_index(method_body_query_match, 2).node
          }

          remove_range(
            &editable_presenter_source,
            int(node_start_byte(wiring_call_capture.node)),
            int(node_end_byte(wiring_call_capture.node))
          )
          inject_at_elems(
            &editable_presenter_source,
            int(node_start_byte(wiring_call_capture.node)),
            ..insert_source
          )
          edit := node_replacement_edit(insert_node, wiring_call_capture.node)
          tree_edit(presenter_tree, &edit)
          presenter_tree = parser_parse_string(parser^, presenter_tree, cstring(raw_data(editable_presenter_source)), u32(len(editable_presenter_source)))
          // cursor seems to be invalidated after edit... run query again.
          query_cursor_exec(cursor, method_calls_query, tree_root_node(presenter_tree))

          replaced = true
        }
      }
    }
  }
  if (replaced) {
    output: []u8
    on_each_return := transmute([]u8)string("onEach(return ")
    if bytes.contains(editable_presenter_source[:], on_each_return) {
      on_each := transmute([]u8)string("onEach(")
      output, _ = bytes.replace_all(editable_presenter_source[:], on_each_return, on_each)
    } else {
      output = editable_presenter_source[:]
    }
    if !os.write_entire_file(presenter_filepath, output) {
      fmt.eprintf("failed to write updated file %s", presenter_filepath)
    }
  }
  return .None
}

Replace_Constructor_Params :: enum {
  None,
  PresenterParseFailed,
  WiringParseFailed
}

replace_presenter_constructor_params :: proc(parser: ^Parser, presenter_filepath: string, wiring_filepath: string) -> (err: Replace_Constructor_Params) {
  presenter_source : []u8
  wiring_source : []u8
  ok : bool
  presenter_source, ok = os.read_entire_file_from_filename(presenter_filepath)
  if !ok {
    return .PresenterParseFailed
  }
  // TODO reuse trees from remove_wiring_from_presenter??
  presenter_tree := parser_parse_string(parser^, nil, cstring(raw_data(presenter_source)), u32(len(presenter_source)))
  wiring_source, ok = os.read_entire_file_from_filename(wiring_filepath)
  if !ok {
    return .WiringParseFailed
  }
  wiring_tree := parser_parse_string(parser^, nil, cstring(raw_data(wiring_source)), u32(len(wiring_source)))

  query_source := `
(class_declaration
 (type_identifier) @class_name
 (primary_constructor
  (class_parameter
   (user_type) @type
  ) @class_parameter
 )
)
`
  error_offset : u32
  error_type : QueryError

  cursor := query_cursor_new()
  defer query_cursor_delete(cursor)

  presenter_params_cursor := query_cursor_new()
  defer query_cursor_delete(presenter_params_cursor)

  class_params_query := query_new(
    language,
    cstring(raw_data(query_source)),
    u32(len(query_source)),
    &error_offset,
    &error_type
  )

  wiring_impl_params_query_match : QueryMatch
  presenter_params_query_match : QueryMatch
  editable_presenter_source : [dynamic]u8
  replaced := false

  query_cursor_exec(cursor, class_params_query, tree_root_node(wiring_tree))

  param_nodes : [dynamic]Node

  for (query_cursor_next_match(cursor, &wiring_impl_params_query_match)) {
    assert(wiring_impl_params_query_match.capture_count == 3)
    class_name := source_text(capture_by_index(wiring_impl_params_query_match, 0), wiring_source)
    if strings.has_suffix(string(class_name), "WiringImpl") {
      wiring_impl_params_capture := capture_by_index(wiring_impl_params_query_match, 2)
      append(&param_nodes, wiring_impl_params_capture.node)
    }
  }

  if len(param_nodes) > 0 {
    resize(&editable_presenter_source, len(presenter_source))
    copy(editable_presenter_source[:], presenter_source[:])
    query_cursor_exec(presenter_params_cursor, class_params_query, tree_root_node(presenter_tree))
    for (query_cursor_next_match(presenter_params_cursor, &presenter_params_query_match)) {
      assert(presenter_params_query_match.capture_count == 3)
      parameter_type := source_text(capture_by_index(presenter_params_query_match, 1), presenter_source)
      if strings.has_suffix(string(parameter_type), "Wiring") {
        parameter_capture := capture_by_index(presenter_params_query_match, 2)
        remove_range(
            &editable_presenter_source,
          int(node_start_byte(parameter_capture.node)),
          int(node_end_byte(parameter_capture.node))
        )
        wiring_impl_source := wiring_source[node_start_byte(param_nodes[0]):node_end_byte(param_nodes[len(param_nodes) - 1])]
        inject_at_elems(
            &editable_presenter_source,
          int(node_start_byte(parameter_capture.node)),
          ..wiring_impl_source
        )
        edit := node_replacement_edit_range(param_nodes[0], param_nodes[len(param_nodes) - 1], parameter_capture.node)
        tree_edit(presenter_tree, &edit)
        presenter_tree = parser_parse_string(parser^, presenter_tree, cstring(raw_data(editable_presenter_source)), u32(len(editable_presenter_source)))
        replaced = true
        break
      }
    }
  }

  if (replaced) {
    if !os.write_entire_file(presenter_filepath, editable_presenter_source[:]) {
      fmt.eprintf("failed to write updated file %s", presenter_filepath)
    }
  }
  return .None
}

UpdateImportList :: enum {
  None,
  PresenterParseFailed,
  WiringParseFailed
}

update_import_list :: proc(parser: ^Parser, presenter_filepath: string, wiring_filepath: string) -> (err: UpdateImportList) {
  presenter_source : []u8
  wiring_source : []u8
  ok : bool
  presenter_source, ok = os.read_entire_file_from_filename(presenter_filepath)
  if !ok {
    return .PresenterParseFailed
  }
  // TODO reuse trees from remove_wiring_from_presenter??
  presenter_tree := parser_parse_string(parser^, nil, cstring(raw_data(presenter_source)), u32(len(presenter_source)))
  wiring_source, ok = os.read_entire_file_from_filename(wiring_filepath)
  if !ok {
    return .WiringParseFailed
  }
  wiring_tree := parser_parse_string(parser^, nil, cstring(raw_data(wiring_source)), u32(len(wiring_source)))

  query_source := `
(import_list) @import_list
`
  error_offset : u32
  error_type : QueryError

  wiring_imports_cursor := query_cursor_new()
  defer query_cursor_delete(wiring_imports_cursor)

  presenter_imports_cursor := query_cursor_new()
  defer query_cursor_delete(presenter_imports_cursor)

  query := query_new(
    language,
    cstring(raw_data(query_source)),
    u32(len(query_source)),
    &error_offset,
    &error_type
  )

  wiring_imports_query_match : QueryMatch
  presenter_imports_query_match : QueryMatch
  editable_presenter_source : [dynamic]u8
  replaced := false

  query_cursor_exec(wiring_imports_cursor, query, tree_root_node(wiring_tree))
  query_cursor_next_match(wiring_imports_cursor, &wiring_imports_query_match)
  assert(wiring_imports_query_match.capture_count == 1)

  resize(&editable_presenter_source, len(presenter_source))
  copy(editable_presenter_source[:], presenter_source[:])

  query_cursor_exec(presenter_imports_cursor, query, tree_root_node(presenter_tree))
  query_cursor_next_match(presenter_imports_cursor, &presenter_imports_query_match)
  assert(presenter_imports_query_match.capture_count == 1)

  wiring_imports_source := source_text(capture_by_index(wiring_imports_query_match, 0), wiring_source)

  inject_at_elems(
      &editable_presenter_source,
    int(node_end_byte(capture_by_index(presenter_imports_query_match, 0).node)),
    ..wiring_imports_source
  )

  if !os.write_entire_file(presenter_filepath, editable_presenter_source[:]) {
    fmt.eprintf("failed to write updated file %s", presenter_filepath)
  }
  return .None
}

Remove_Wiring_Bindings_Error :: enum {
  None,
  KeyParseFailed,
}

remove_wiring_bindings :: proc(parser: ^Parser, key_filepath: string) -> (err: Remove_Wiring_Bindings_Error) {
  source, ok := os.read_entire_file_from_filename(key_filepath)
  if !ok {
    return .KeyParseFailed
  }
  tree := parser_parse_string(parser^, nil, cstring(raw_data(source)), u32(len(source)))

  cursor := query_cursor_new()
  defer query_cursor_delete(cursor)
  error_offset : u32
  error_type : QueryError

  query_source := `
(value_argument
  (simple_identifier)
  (call_expression
    (simple_identifier) @call_name
    (call_suffix
     (annotated_lambda
      (lambda_literal
       (statements
        (call_expression) @binding_call
       )
      )
     )
    )
  )
) @value_arg
`
  query := query_new(
    language,
    cstring(raw_data(query_source)),
    u32(len(query_source)),
    &error_offset,
    &error_type
  )

  query_match : QueryMatch
  query_cursor_exec(cursor, query, tree_root_node(tree))
  bind_call_count := 0
  wiring_bind_call_node : Node
  entire_bindings_param_node : Node
  for (query_cursor_next_match(cursor, &query_match)) {
    assert(query_match.capture_count == 3)
    call_name := source_text(capture_by_index(query_match, 0), source)
    // if ToothpickScreenBindings lambda will contain multiple "module.bind" calls,
    // each of them will come as a separate match in this for-loop => count them to
    // decide how to act after "for"
    if string(call_name) == "ToothpickScreenBindings" {
      bind_call_capture := capture_by_index(query_match, 1)
      if strings.contains(string(source_text(bind_call_capture, source)), "Wiring::class") {
        wiring_bind_call_node = bind_call_capture.node
        entire_capture := capture_by_index(query_match, 2)
        entire_bindings_param_node = entire_capture.node
      }
      bind_call_count += 1
    }
  }
  if wiring_bind_call_node.id != nil {
    editable_source : [dynamic]u8
    resize(&editable_source, len(source))
    copy(editable_source[:], source[:])
    if bind_call_count == 1  {
      assert(entire_bindings_param_node.id != nil)
      remove_range(
        &editable_source,
        int(node_start_byte(entire_bindings_param_node)),
        int(node_end_byte(entire_bindings_param_node))
      )
    } else if bind_call_count > 1 && wiring_bind_call_node.id != nil {
      remove_range(
        &editable_source,
        int(node_start_byte(wiring_bind_call_node)),
        int(node_end_byte(wiring_bind_call_node))
      )
    }
    if !os.write_entire_file(key_filepath, editable_source[:]) {
      fmt.eprintf("failed to write updated file %s", key_filepath)
    }
  }
  return .None
}


capture_by_index :: proc(match: QueryMatch, capture_index: u32) -> QueryCapture {
  i: u16
  found := false
  for idx in 0..<match.capture_count {
    if match.captures[idx].index == capture_index {
      i = idx
      found = true
      break
    }
  }
  assert(found)
  return match.captures[i]
}

// Calculates an TS "edit" for replacing dst_node content with src_node content
node_replacement_edit :: proc(src_node: Node, dst_node: Node) -> InputEdit {
  return node_replacement_edit_range(src_node, src_node, dst_node)
}

// Calculates an TS "edit" for replacing dst_node content with range of nodes described by src_node_start, src_node_end
node_replacement_edit_range :: proc(src_node_start: Node, src_node_end: Node, dst_node: Node) -> InputEdit {
  dst_start_byte := node_start_byte(dst_node)
  dst_end_byte := node_end_byte(dst_node)
  src_start_byte := node_start_byte(src_node_start)
  src_end_byte := node_end_byte(src_node_end)
  dst_start_point := node_start_point(dst_node)
  dst_end_point := node_end_point(dst_node)
  src_start_point := node_start_point(src_node_start)
  src_end_point := node_end_point(src_node_end)
  edit := InputEdit{
    start_byte = dst_start_byte,
    old_end_byte = dst_end_byte,
    new_end_byte = dst_start_byte + (src_end_byte - src_start_byte),
    start_point = dst_start_point,
    old_end_point = dst_end_point,
    new_end_point = Point{
      row = dst_start_point.row + (dst_end_point.row - src_end_point.row),
      column = dst_end_point.column
    }
  }
  return edit
}

source_text :: proc(capture: QueryCapture, source: []u8) -> []u8 {
  start := node_start_byte(capture.node)
  end := node_end_byte(capture.node)
  return source[start:end]
}

walk_proc :: proc(info: os.File_Info, in_err: os.Errno, user_data: rawptr) -> (err: os.Errno, skip_dir: bool) {
  if !info.is_dir {
    return in_err, false
  }
  if (info.name == "build" || strings.has_prefix(info.name, ".")) {
    return in_err, true
  }

  handle, open_err := os.open(info.fullpath, os.O_RDONLY)
  if (open_err != 0) {
    fmt.eprintf("error opening directory: %s, error=%d", info.fullpath, open_err)
    return 0, true
  }
  files, dir_err := os.read_dir(handle, -1)
  if (dir_err != 0) {
    fmt.eprintf("error reading directory: %s, error=%d", info.fullpath, dir_err)
    return 0, true
  }
  presenter_filepath := ""
  wiring_filepath := ""
  key_filepath := ""
  has_subdirs := false
  for fi in files {
    if strings.has_suffix(fi.name, "Presenter.kt") {
      presenter_filepath = fi.fullpath
    }
    if strings.has_suffix(fi.name, "Wiring.kt") {
      wiring_filepath = fi.fullpath
    }
    if strings.has_suffix(fi.name, "Key.kt") {
      key_filepath = fi.fullpath
    }
    if fi.is_dir {
      has_subdirs = true
    }
  }
  if len(presenter_filepath) != 0 && len(wiring_filepath) != 0 {
    parser := cast(^Parser)user_data
    err := remove_wiring_from_presenter(parser, presenter_filepath, wiring_filepath)
    if err != .None {
      fmt.eprintf("Failed to remove wiring from:\n  %s\n  %s\n,  error=%s", presenter_filepath, wiring_filepath, err)
    } else {
      err1 := update_import_list(parser, presenter_filepath, wiring_filepath)
      if err1 != .None {
        fmt.eprintf("Failed to move imports in:\n  %s\n  %s\n,  error=%s", presenter_filepath, wiring_filepath, err1)
      } else {
        err2 := replace_presenter_constructor_params(parser, presenter_filepath, wiring_filepath)
        if err2 != .None {
          fmt.eprintf("Failed to replace params in:\n  %s\n  %s\n,  error=%s", presenter_filepath, wiring_filepath, err2)
        } else {
          os.remove(wiring_filepath)
        }
      }
    }
  }
  if len(key_filepath) != 0 {
    parser := cast(^Parser)user_data
    err := remove_wiring_bindings(parser, key_filepath)
    if err != nil {
      fmt.eprintf("Failed to process key file:\n  %s\n,  error=%s", key_filepath, err)
    }
  }
  // if this dir has no subdirs, no need to walk files in it: we've analyzed it
  return in_err, !has_subdirs
}

write_to_dot_file :: proc(root: Tree) -> (os.Errno) {
  handle, err := os.open( "/tmp/parse-tree.dot", os.O_RDWR)
  if err != 0 {
    return err;
  }
  tree_print_dot_graph(root, c.int(handle))
  return 0
}

main :: proc() {
  if (len(os.args) < 2) {
    fmt.eprintf(`
  Usage:
     odin-kotlin-parse <path>
`)
    os.exit(1)
  }

  parser := parser_new()
  parser_set_language(parser, language)

  root := os.args[1]
  err := filepath.walk(root, walk_proc, &parser)
  if (err != 0) {
    fmt.eprintf("Failed to search directory %s, error=%d", root, err)
  }
}
