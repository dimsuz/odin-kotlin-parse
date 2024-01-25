package main

import "core:fmt"
import "core:path/filepath"
import "core:os"
import "core:strings"
import "core:c"

foreign import parser "clib/tree-sitter-kotlin/parser.a"
foreign import ts "clib/tree-sitter-kotlin/libtree-sitter.a"

Parser :: rawptr;
Language :: rawptr;
Tree :: rawptr;
Query :: rawptr;

QueryError :: u8;

Node :: struct  #packed {
  ctx: [4]u32,
  id: rawptr,
  tree: Tree,
};

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

@(link_prefix = "ts_")
foreign ts {
  parser_new :: proc() -> Parser ---;
  parser_set_language :: proc(parser: Parser, language: Language) ---;
  parser_parse_string :: proc (parser: Parser, tree: Tree, source: cstring, source_len: u32) -> Tree ---;
  tree_print_dot_graph :: proc (tree: Tree, file: c.int) ---;
  tree_root_node :: proc (tree: Tree) -> Node ---;
  node_string :: proc(root_node: Node) -> cstring ---;
  query_new :: proc(language: Language, source: cstring, source_len: u32, error_offset: ^u32, error_type: ^QueryError) -> Query ---;
}

foreign parser {
  tree_sitter_kotlin :: proc() -> Language ---;
}

Process_Kotlin_File_Error :: enum {
  Parse_Failed = 1
}

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
  source : []u8
  ok : bool
  source, ok = os.read_entire_file_from_filename(presenter_filepath)
  if !ok {
    return .PresenterParseFailed
  }
  presenter_tree := parser_parse_string(parser^, nil, cstring(raw_data(source)), u32(len(source)))
  source, ok = os.read_entire_file_from_filename(wiring_filepath)
  if !ok {
    return .WiringParseFailed
  }
  wiring_tree := parser_parse_string(parser^, nil, cstring(raw_data(source)), u32(len(source)))
  // tree := parser_parse_string(parser^, nil, cstring(raw_data(source)), u32(len(source)))
  // root_node := tree_root_node(tree)
  fmt.eprintf("Source tree of %s:\n%s\n\n", presenter_filepath, node_string(tree_root_node(presenter_tree)))
  fmt.eprintf("Source tree of %s:\n%s\n\n", wiring_filepath, node_string(tree_root_node(wiring_tree)))
  return .None
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
  has_subdirs := false
  for fi in files {
    if strings.has_suffix(fi.name, "Presenter.kt") {
      presenter_filepath = fi.fullpath
    }
    if strings.has_suffix(fi.name, "Wiring.kt") {
      wiring_filepath = fi.fullpath
    }
    if fi.is_dir {
      has_subdirs = true
    }
  }
  if len(presenter_filepath) != 0 && len(wiring_filepath) != 0 {
    parser := cast(^Parser)user_data
    err := remove_wiring_from_presenter(parser, presenter_filepath, wiring_filepath)
    if err != nil {
      fmt.eprintf("Failed to process pair:\n  %s\n  %s\n,  error=%s", presenter_filepath, wiring_filepath, err)
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
  parser_set_language(parser, tree_sitter_kotlin())

  root := os.args[1]
  err := filepath.walk(root, walk_proc, &parser)
  if (err != 0) {
    fmt.eprintf("Failed to search directory %s, error=%d", root, err)
  }
}
