package main

import "core:fmt"
import "core:path/filepath"
import "core:os"
import "core:strings"

Process_Kotlin_File_Error :: enum {
  Parse_Failed = 1
}

process_kotlin_file :: proc(filepath: string) -> (err: Process_Kotlin_File_Error) {
  fmt.eprintf("visiting %s\n", filepath)
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

main :: proc() {
  if (len(os.args) < 2) {
    fmt.eprintf(`
  Usage:
     odin-kotlin-parse <path>
`)
    os.exit(1)
  }

  root := os.args[1]
  err := filepath.walk(root, walk_proc, nil)
  if (err != 0) {
    fmt.eprintf("Failed to search directory %s, error=%d", root, err)
  }
}
