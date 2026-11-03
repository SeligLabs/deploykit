// Command deploy-tui is the terminal UI for a deploykit deploy.
//
//	deploy-tui -- bash scripts/deploy/deploy.sh all   (an app's deploy.sh)
//
// It owns the terminal and runs the deploy as a child in a session of its
// own (no controlling terminal: a tool that reaches for /dev/tty fails
// instead of drawing over the UI), with DEPLOY_UI=tui. The deploy
// writes its state under DEPLOY_WORK (lib/tracker.sh), asks its
// questions through files there (lib/prompt.sh), and prints plain lines,
// a summary, which goes to the output box's first page and to the run's
// folder under ~/.cache/<APP_SLUG>/deploy-logs/; each thread's own output has a
// page of its own and is copied there at the end. Ctrl-C reaches the deploy's whole process group
// as a terminal's would. When the deploy ends the screen stays until q; then
// the output's last lines and the log's path print to the terminal, and the
// exit code is the deploy's.
//
// The engine starts it (tui/build.sh builds it once per source change) when
// it runs in a terminal and DEPLOY_TUI isn't 0. Without it the deploy
// runs as before.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/charmbracelet/x/ansi"

	tea "charm.land/bubbletea/v2"
)

func main() {
	args := os.Args[1:]
	if len(args) > 0 && args[0] == "--" {
		args = args[1:]
	}
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "usage: deploy-tui -- <command> [args...]")
		os.Exit(2)
	}
	os.Exit(run(args))
}

func run(args []string) int {
	work, err := os.MkdirTemp("", appSlug()+"-deploy-ui.")
	if err != nil {
		fmt.Fprintln(os.Stderr, "deploy-tui:", err)
		return 1
	}
	// The deploy's plan file holds secrets: whatever happens, it goes.
	defer os.RemoveAll(work)

	root, _ := os.Getwd()
	if r, err := filepath.EvalSymlinks(root); err == nil {
		root = r
	}

	out, in, err := os.Pipe()
	if err != nil {
		fmt.Fprintln(os.Stderr, "deploy-tui:", err)
		return 1
	}
	devnull, _ := os.Open(os.DevNull)
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Env = append(os.Environ(),
		"DEPLOY_UI=tui",
		"DEPLOY_WORK="+work,
		fmt.Sprintf("DEPLOY_TUI_PID=%d", os.Getpid()),
	)
	cmd.Stdin = devnull
	cmd.Stdout = in
	cmd.Stderr = in
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		fmt.Fprintln(os.Stderr, "deploy-tui:", err)
		return 1
	}
	in.Close()
	pgid := cmd.Process.Pid

	m := newModel(work, root, LoadHistory(TimingsPath()), pgid)
	runDir, logFile := openLog(args)
	if logFile != nil {
		defer logFile.Close()
		m.log = logFile
	}
	m.runDir = runDir
	m.notify = notifyDesk
	p := tea.NewProgram(m, tea.WithoutSignalHandler())

	// The deploy's output, line by line, then its exit code.
	exited := make(chan int, 1)
	go func() {
		r := bufio.NewReaderSize(out, 64*1024)
		for {
			line, err := r.ReadString('\n')
			if len(line) > 0 {
				p.Send(lineMsg(outputLine(trimNewline(line))))
			}
			if err != nil {
				if !errors.Is(err, io.EOF) {
					p.Send(lineMsg("deploy-tui: reading the deploy's output: " + err.Error()))
				}
				break
			}
		}
		code := exitCode(cmd.Wait())
		exited <- code
		p.Send(exitMsg{code})
	}()

	// Signals from outside: an interrupt is a stop; a terminate or a hangup
	// goes to the deploy as it is (it cleans up and exits 143 or 129).
	sigs := make(chan os.Signal, 4)
	signal.Notify(sigs, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		for s := range sigs {
			if s == syscall.SIGINT {
				p.Send(stopMsg{})
				continue
			}
			p.Send(goneMsg{})
			_ = syscall.Kill(-pgid, s.(syscall.Signal))
		}
	}()

	final, err := p.Run()
	if err != nil {
		// The UI broke, not the deploy: let it finish where it can be seen.
		fmt.Fprintf(os.Stderr, "deploy-tui: %v. The deploy goes on without the UI.\n", err)
		go func() { _, _ = io.Copy(os.Stdout, out) }()
	}
	code := <-exited
	if fm, ok := final.(*model); ok {
		keepLogs(fm, runDir)
		if fm.done {
			code = fm.exitCode
			printSummary(fm, runDir)
		}
	}
	return code
}

// keepLogs copies every thread's and lane's log into the run's folder: the
// deploy removes $WORK, and the next run overwrites the lanes' logs.
func keepLogs(m *model, dir string) {
	if dir == "" {
		return
	}
	copyTo := func(src, name string) {
		b, err := os.ReadFile(src)
		if err != nil {
			return
		}
		name = strings.Map(func(r rune) rune {
			if r == '/' || r == ' ' {
				return '-'
			}
			return r
		}, name)
		_ = os.WriteFile(filepath.Join(dir, name+".log"), b, 0o600)
	}
	// By key, which is unique: titles can differ only in case (the "web-build"
	// check and the "Web build" thread), one file on a Mac's disk.
	for _, t := range m.snap.Threads {
		copyTo(t.Log, t.Key)
	}
	for _, l := range m.snap.Lanes {
		if l.Log != "" {
			copyTo(l.Log, "lane-"+l.Name)
		}
	}
}

// keepRunFolders is how many runs' folders stay in the log folder:
// DEPLOY_KEEP_LOGS (the app's env, which the engine loads before it starts the
// UI), else 5.
func keepRunFolders() int {
	v := strings.Trim(strings.TrimSpace(os.Getenv("DEPLOY_KEEP_LOGS")), `"'`)
	if n, err := strconv.Atoi(v); err == nil && n >= 1 {
		return n
	}
	return 5
}

// openLog makes this run's folder, named for when it started and what it
// runs, with its summary.log (the deploy's own output) open, and drops the
// oldest runs past keepRunFolders. No log is no reason to stop.
func openLog(args []string) (string, *os.File) {
	base := filepath.Join(filepath.Dir(TimingsPath()), "deploy-logs")
	mode := "deploy"
	if n := len(args); n > 0 {
		mode = strings.TrimSuffix(filepath.Base(args[n-1]), ".sh")
	}
	dir := filepath.Join(base, time.Now().Format("2006-01-02-150405")+"-"+mode)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", nil
	}
	f, err := os.OpenFile(filepath.Join(dir, "summary.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return "", nil
	}
	keep := keepRunFolders()
	if old, _ := filepath.Glob(filepath.Join(base, "*")); len(old) > keep {
		sort.Strings(old)
		for _, o := range old[:len(old)-keep] {
			_ = os.RemoveAll(o)
		}
	}
	return dir, f
}

// printSummary leaves the run in the terminal after the screen closes: the
// summary's last lines (the deploy's own last word and its slowest steps
// among them) and the folder with every log of the run.
func printSummary(m *model, logPath string) {
	const tail = 30
	lines := m.output
	if len(lines) > tail {
		lines = lines[len(lines)-tail:]
	}
	for _, l := range lines {
		fmt.Println(l)
	}
	fmt.Println()
	fmt.Println(ansi.Strip(m.finalLine()))
	if logPath != "" {
		home, _ := os.UserHomeDir()
		if home != "" && strings.HasPrefix(logPath, home+"/") {
			logPath = "~/" + strings.TrimPrefix(logPath, home+"/")
		}
		fmt.Println("Every log of this run: " + logPath + "/")
	}
}

// notifyDesk tells whoever is at the Mac that the deploy ended: the
// terminal's bell, and a notification (it shows even when the terminal is
// behind other windows). Nothing to do elsewhere, without osascript, or with
// DEPLOY_NOTIFY=0.
func notifyDesk(headline, message string) {
	if os.Getenv("DEPLOY_NOTIFY") == "0" {
		return
	}
	if tty, err := os.OpenFile("/dev/tty", os.O_WRONLY, 0); err == nil {
		_, _ = tty.WriteString("\a")
		tty.Close()
	}
	if _, err := exec.LookPath("osascript"); err != nil {
		return
	}
	quote := func(s string) string {
		return `"` + strings.NewReplacer(`\`, `\\`, `"`, `\"`).Replace(s) + `"`
	}
	if len(message) > 200 {
		message = message[:200] + "…"
	}
	script := "display notification " + quote(message) + " with title " + quote(appSlug()+" deploy") +
		" subtitle " + quote(strings.ToLower(headline)) + ` sound name "Glass"`
	_ = exec.Command("osascript", "-e", script).Run()
}

func trimNewline(s string) string {
	if n := len(s); n > 0 && s[n-1] == '\n' {
		return s[:n-1]
	}
	return s
}

// exitCode is a finished command's status, 128 + the signal when a signal
// ended it.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal())
		}
		return ee.ExitCode()
	}
	return 1
}
