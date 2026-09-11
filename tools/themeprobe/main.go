package main

import (
	"fmt"
	"os"

	lua "github.com/wippyai/go-lua"
)

func main() {
	l := lua.NewState()
	defer l.Close()
	if err := l.DoFile(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, "ERROR:", err)
		os.Exit(1)
	}
}
