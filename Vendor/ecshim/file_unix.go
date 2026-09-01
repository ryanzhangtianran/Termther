package main

import "os"

func newFile(fd int, name string) *os.File { return os.NewFile(uintptr(fd), name) }
