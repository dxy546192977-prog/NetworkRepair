package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func printBanner() {
	fmt.Println("")
	fmt.Println("================================================================")
	fmt.Println("  Cursor Network Repair Assistant")
	fmt.Println("================================================================")
	fmt.Println("  Preparing PowerShell session...")
	fmt.Println("")
}

func printFooter(exitCode int) {
	fmt.Println("")
	fmt.Println("================================================================")
	if exitCode == 0 {
		fmt.Printf("  Finished. ExitCode: %d\n", exitCode)
	} else {
		fmt.Printf("  Finished with issues. ExitCode: %d\n", exitCode)
	}
	fmt.Println("================================================================")
}

func failAndExit(msg string) {
	fmt.Println("")
	fmt.Println("================================================================")
	fmt.Println("  [ERROR] " + msg)
	fmt.Println("================================================================")
	os.Exit(1)
}

func main() {
	exePath, err := os.Executable()
	if err != nil {
		failAndExit("Failed to locate executable path")
	}

	exeDir := filepath.Dir(exePath)
	scriptPath := filepath.Join(exeDir, "src", "cursor-model-network-repair.ps1")
	if _, err := os.Stat(scriptPath); err != nil {
		failAndExit(`Script not found: "` + scriptPath + `"`)
	}

	printBanner()

	psArgs := []string{
		"-NoProfile",
		"-ExecutionPolicy",
		"Bypass",
		"-File",
		scriptPath,
	}
	psArgs = append(psArgs, os.Args[1:]...)

	cmd := exec.Command("powershell.exe", psArgs...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	cmd.Stdin = os.Stdin

	err = cmd.Run()
	if err == nil {
		printFooter(0)
		os.Exit(0)
	}

	if exitErr, ok := err.(*exec.ExitError); ok {
		exitCode := exitErr.ExitCode()
		printFooter(exitCode)
		os.Exit(exitCode)
	}

	failAndExit("Failed to run powershell.exe: " + strings.TrimSpace(err.Error()))
}
