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

Node :: struct  #packed {
  ctx: [4]u32,
  id: rawptr,
  tree: Tree,
};

@(link_prefix = "ts_")
foreign ts {
  parser_new :: proc() -> Parser ---;
  parser_set_language :: proc(parser: Parser, language: Language) ---;
  parser_parse_string :: proc (parser: Parser, tree: Tree, source: cstring, source_len: u32) -> Tree ---;
  tree_print_dot_graph :: proc (tree: Tree, file: c.int) ---;
  tree_root_node :: proc (tree: Tree) -> Node ---;
  node_string :: proc(root_node: Node) -> cstring ---;
}

foreign parser {
  tree_sitter_kotlin :: proc() -> Language ---;
}

Process_Kotlin_File_Error :: enum {
  Parse_Failed = 1
}

process_kotlin_file :: proc(filepath: string) -> (err: Process_Kotlin_File_Error) {
  // fmt.eprintf("visiting %s\n", filepath)
  return nil
}

walk_proc :: proc(info: os.File_Info, in_err: os.Errno, user_data: rawptr) -> (err: os.Errno, skip_dir: bool) {
  if info.is_dir && (info.name == "build" || strings.has_prefix(info.name, ".")) {
    return in_err, true
  }
  if !info.is_dir && filepath.ext(info.name) == ".kt" {
    err := process_kotlin_file(info.fullpath)
    if err != nil {
      fmt.eprintf("Failed to process file [%s]: %s\n", info.fullpath, err)
    }
  }
  return in_err, false
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
  source := "package com.example.test\n"
  tree := parser_parse_string(parser, nil, strings.unsafe_string_to_cstring(source), u32(len(source)))
  root_node := tree_root_node(tree)
  fmt.eprintf("Source tree:\n%s\n", node_string(root_node))

  root := os.args[1]
  err := filepath.walk(root, walk_proc, nil)
  if (err != 0) {
    fmt.eprintf("Failed to search directory %s, error=%d", root, err)
  }
}
