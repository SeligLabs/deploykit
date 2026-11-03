package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

func historyFrom(lines ...string) *History {
	h := &History{samples: map[string][]float64{}}
	for _, l := range lines {
		h.add(l)
	}
	return h
}

func TestEstPrefersTheModeAndTakesTheMedian(t *testing.T) {
	h := historyFrom(
		"2026-11-01 10:00:00 all iOS Archive 300",
		"2026-11-01 11:00:00 all iOS Archive 100",
		"2026-11-01 12:00:00 all iOS Archive 200",
		"2026-11-01 12:00:00 ios iOS Archive 900",
	)
	if got, ok := h.Est("all", "iOS", "Archive"); !ok || got != 200 {
		t.Fatalf("all: got %v %v, want 200", got, ok)
	}
	if got, ok := h.Est("ios", "iOS", "Archive"); !ok || got != 900 {
		t.Fatalf("ios: got %v %v, want 900", got, ok)
	}
	// Another mode falls back to every mode's runs.
	if got, ok := h.Est("tv", "iOS", "Archive"); !ok || got != 250 {
		t.Fatalf("fallback: got %v %v, want 250 (median of 100 200 300 900)", got, ok)
	}
	if _, ok := h.Est("all", "iOS", "Gate"); ok {
		t.Fatal("a wait has no estimate")
	}
}

func TestEstKeepsOnlyRecentRuns(t *testing.T) {
	var lines []string
	for i := 0; i < 10; i++ {
		lines = append(lines, "d t all Desktop Package 1300")
	}
	for i := 0; i < keepRuns; i++ {
		lines = append(lines, "d t all Desktop Package 300")
	}
	if got, _ := historyFrom(lines...).Est("all", "Desktop", "Package"); got != 300 {
		t.Fatalf("got %v, want 300: old runs should age out", got)
	}
}

func TestStepRemaining(t *testing.T) {
	h := historyFrom("d t all iOS Archive 100")
	// A count goes by its rate: 50 of 200 in 25 s leaves 75 s.
	p := Progress{Steps: []string{"Archive"}, States: []string{"r"}, Cur: 0, N: 50, Total: 200, StepStart: 1000}
	left, frac, ok := h.StepRemaining("all", "iOS", p, 1025)
	if !ok || left != 75 || frac != 0.25 {
		t.Fatalf("count: got %v %v %v", left, frac, ok)
	}
	// Without a count, history: 40 s into a 100 s step leaves 60.
	p = Progress{Steps: []string{"Archive"}, States: []string{"r"}, Cur: 0, StepStart: 1000}
	left, frac, ok = h.StepRemaining("all", "iOS", p, 1040)
	if !ok || left != 60 || frac != 0.4 {
		t.Fatalf("history: got %v %v %v", left, frac, ok)
	}
	// Past its usual time it keeps a tenth in hand and never reaches full.
	left, frac, _ = h.StepRemaining("all", "iOS", p, 1500)
	if left != 10 || frac >= 1 {
		t.Fatalf("overrun: got %v %v", left, frac)
	}
	// Lint's side-by-side checks: the count, no single step.
	p = Progress{Steps: []string{"a", "b"}, States: []string{"d", "r"}, Cur: -1, N: 3, Total: 4}
	if _, frac, _ = h.StepRemaining("all", "Lint", p, 0); frac != 0.75 {
		t.Fatalf("lint: got %v", frac)
	}
}

func TestOverallWaitsForTheGate(t *testing.T) {
	h := historyFrom(
		"d t all Lint - 120",
		"d t all Infra - 60",
		"d t all Web - 20",
		"d t all Release - 10",
		"d t all iOS Archive 100",
		"d t all iOS Upload 50",
	)
	s := Snapshot{
		Mode:        "all",
		Stages:      []string{"Preflight", "Lint", "Infra", "Web", "iOS", "Release"},
		StageStates: []string{"d", "p", "p", "p", "b", "p"},
		CurStage:    0,
		Lanes: []Lane{{Name: "iOS", Alive: true, Progress: Progress{
			Steps: []string{"Archive", "Gate", "Upload"}, States: []string{"r", "p", "p"}, Cur: 0, StepStart: 0,
		}}},
	}
	// Foreground to Web: 200. The archive (100 left) is done well before,
	// so the upload starts at 200 and ends at 250; Release adds 10.
	left, ok := h.Overall(s, 0)
	if !ok || left != 260 {
		t.Fatalf("got %v %v, want 260", left, ok)
	}
	// A slow archive is the long pole instead: 400 + 50 + 10.
	h.add("d t all iOS Archive 400")
	h.add("d t all iOS Archive 400")
	if left, _ = h.Overall(s, 0); left != 460 {
		t.Fatalf("got %v, want 460", left)
	}
}

func put(t *testing.T, dir, key, value string) {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, key), []byte(value+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestReadSnapshot(t *testing.T) {
	work := t.TempDir()
	st := filepath.Join(work, "status")
	put(t, st, "stages", "Preflight Lint iOS")
	put(t, st, "mode", "all")
	put(t, st, "started", "1000")
	put(t, st, "stage_states", "d r b")
	put(t, st, "cur_stage", "1")
	put(t, st, "steps", "go-test js-test")
	put(t, st, "step_states", "d r")
	put(t, st, "cur_step", "-1")
	put(t, st, "n", "1")
	put(t, st, "total", "2")
	put(t, st, "label", "checks")
	lane := filepath.Join(st, "bg", "iOS")
	put(t, lane, "steps", "Check Archive Gate Upload")
	put(t, lane, "step_states", "d d d d")
	put(t, lane, "ok", "1")
	put(t, work, "ios-result", "0.19.3 (166) uploaded to TestFlight")

	s := ReadSnapshot(work)
	if !s.Ready || s.Mode != "all" || s.CurStage != 1 || s.StageState(2) != "b" {
		t.Fatalf("run: %+v", s)
	}
	if s.Fg.Cur != -1 || s.Fg.N != 1 || s.Fg.Total != 2 || s.Fg.Label != "checks" {
		t.Fatalf("foreground: %+v", s.Fg)
	}
	l, ok := s.Lane("iOS")
	if !ok || !l.OK || l.Alive || l.Result != "0.19.3 (166) uploaded to TestFlight" {
		t.Fatalf("lane: %+v", l)
	}
	if ReadSnapshot(t.TempDir()).Ready {
		t.Fatal("an empty work folder isn't ready")
	}
}

func TestCleanLine(t *testing.T) {
	cases := map[string]string{
		"[19:49:12]: \x1b[35m\x1b[33m▸\x1b[0m \x1b[39;1mCompiling\x1b[0m Foo.m": "Compiling Foo.m",
		"Uploading 10%\rUploading 50%\r":                                        "Uploading 50%",
		"  • signing  file=demo.app":                                            "• signing  file=demo.app",
	}
	for in, want := range cases {
		if got := cleanLine(in); got != want {
			t.Errorf("cleanLine(%q) = %q, want %q", in, got, want)
		}
	}
	dir := t.TempDir()
	log := filepath.Join(dir, "lane.log")
	_ = os.WriteFile(log, []byte("first\nCompiling A.swift\n+------+------+\n\n"), 0o644)
	if got := lastLogLine(log); got != "Compiling A.swift" {
		t.Fatalf("lastLogLine: %q", got)
	}
}

// cleanEnv is this process's environment without the deploy's own variables.
// Lint runs these tests inside a deploy, under the deploy UI, so they
// inherit DEPLOY_UI=tui and its WORK; a test that runs bash must set
// what it means to test, not take the deploy's (TestThreadRun's "without
// the UI" case failed in a real deploy, 2026-11-03).
func cleanEnv() []string {
	var out []string
	for _, kv := range os.Environ() {
		key, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(key, "DEPLOY_") || key == "WORK" || key == "S" {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// askBash runs a prompt from lib/prompt.sh under the deploy UI's protocol
// and answers it, as the UI does; it returns the question and what bash
// printed.
func askBash(t *testing.T, script, answer string) (Question, string) {
	t.Helper()
	work := t.TempDir()
	prompt, _ := filepath.Abs("../lib/prompt.sh")
	cmd := exec.Command("bash", "-c", "set -euo pipefail; source \"$PROMPT\"; "+script)
	cmd.Env = append(cleanEnv(), "PROMPT="+prompt, "DEPLOY_UI=tui", "WORK="+work,
		"DEPLOY_TUI_PID="+strconv.Itoa(os.Getpid()))
	var out strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	var q Question
	for {
		var ok bool
		if q, ok = ReadQuestion(work); ok {
			break
		}
		if time.Now().After(deadline) {
			_ = cmd.Process.Kill()
			t.Fatalf("no question; bash printed %q", out.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := WriteAnswer(work, q, answer); err != nil {
		t.Fatal(err)
	}
	if err := cmd.Wait(); err != nil {
		t.Fatalf("bash: %v; printed %q", err, out.String())
	}
	return q, out.String()
}

func TestAskProtocolWithBash(t *testing.T) {
	q, out := askBash(t, `PROMPT_TITLE="Start the deploy?" pick 0 Start "" Cancel; echo "PICKED=$PICKED"`, "2")
	if q.Kind != "pick" || q.Title != "Start the deploy?" || q.Default != "0" ||
		strings.Join(q.Options, "|") != "Start||Cancel" {
		t.Fatalf("pick question: %+v", q)
	}
	if !strings.Contains(out, "PICKED=2") {
		t.Fatalf("pick: %q", out)
	}

	q, out = askBash(t, `pick_many a b c; echo "PICKS=${PICKS[*]}"`, "1 0 1")
	if q.Kind != "many" || len(q.Options) != 3 || !strings.Contains(out, "PICKS=1 0 1") {
		t.Fatalf("many: %+v %q", q, out)
	}

	q, out = askBash(t, `if confirm "Apply this plan to production?"; then echo YES; else echo NO; fi`, "n")
	if q.Kind != "confirm" || q.Title != "Apply this plan to production?" || !strings.Contains(out, "NO") {
		t.Fatalf("confirm: %+v %q", q, out)
	}

	q, out = askBash(t, `ask_line Build 166; echo "GOT=$ASK_ANSWER"`, "170")
	if q.Kind != "text" || q.Default != "166" || !strings.Contains(out, "GOT=170") {
		t.Fatalf("text: %+v %q", q, out)
	}

	_, out = askBash(t, `ask_lines "Note"; printf 'GOT=%s|' "$ASK_ANSWER"`, "line one\nline two")
	if !strings.Contains(out, "GOT=line one\nline two|") {
		t.Fatalf("lines: %q", out)
	}
}

func TestAskStopsWhenTheUIIsGone(t *testing.T) {
	work := t.TempDir()
	prompt, _ := filepath.Abs("../lib/prompt.sh")
	cmd := exec.Command("bash", "-c", `source "$PROMPT"; pick 0 a b`)
	// The pid of a process that has finished: certainly not running, on any
	// system (a made-up number can be someone's).
	done := exec.Command("true")
	if err := done.Run(); err != nil {
		t.Fatal(err)
	}
	gone := strconv.Itoa(done.ProcessState.Pid())
	cmd.Env = append(cleanEnv(), "PROMPT="+prompt, "DEPLOY_UI=tui", "WORK="+work, "DEPLOY_TUI_PID="+gone)
	finished := make(chan error, 1)
	go func() { finished <- cmd.Run() }()
	select {
	case err := <-finished:
		if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 129 {
			t.Fatalf("want exit 129, got %v", err)
		}
	case <-time.After(10 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("bash kept waiting for a UI that is gone")
	}
}

func key(s string) tea.KeyPressMsg {
	switch s {
	case "enter":
		return tea.KeyPressMsg{Code: tea.KeyEnter}
	case "down":
		return tea.KeyPressMsg{Code: tea.KeyDown}
	case "up":
		return tea.KeyPressMsg{Code: tea.KeyUp}
	case "space":
		return tea.KeyPressMsg{Code: tea.KeySpace, Text: " "}
	case "ctrl+c":
		return tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl}
	}
	r := []rune(s)[0]
	return tea.KeyPressMsg{Code: r, Text: s}
}

func TestKeysAnswerQuestions(t *testing.T) {
	work := t.TempDir()
	_ = os.MkdirAll(filepath.Join(work, "ask"), 0o755)
	m := newModel(work, "", historyFrom(), 0)

	// A pick skips separators both ways and answers its index.
	m.ask(Question{ID: 1, Kind: "pick", Default: "0", Options: []string{"Start", "---", "Cancel"}})
	m.Update(key("down"))
	if m.cursor != 2 {
		t.Fatalf("down skips the separator: cursor %d", m.cursor)
	}
	m.Update(key("up"))
	if m.cursor != 0 {
		t.Fatalf("up skips it too: cursor %d", m.cursor)
	}
	m.Update(key("down"))
	m.Update(key("enter"))
	if b, _ := os.ReadFile(answerPath(work, 1)); string(b) != "2\n" || m.q != nil {
		t.Fatalf("pick answer %q, question %v", b, m.q)
	}

	// A confirm ignores Enter until a side is chosen, as the old [y/n] did.
	m.ask(Question{ID: 2, Kind: "confirm", Title: "Apply?"})
	m.Update(key("enter"))
	if m.q == nil {
		t.Fatal("Enter alone answered a confirm")
	}
	m.Update(key("n"))
	if b, _ := os.ReadFile(answerPath(work, 2)); string(b) != "n\n" {
		t.Fatalf("confirm answer %q", b)
	}

	// A checklist starts all ticked; space unticks.
	m.ask(Question{ID: 3, Kind: "many", Options: []string{"a", "b"}})
	m.Update(key("down"))
	m.Update(key("space"))
	m.Update(key("enter"))
	if b, _ := os.ReadFile(answerPath(work, 3)); string(b) != "1 0\n" {
		t.Fatalf("many answer %q", b)
	}

	// Ctrl-C stops: a first press, then a second; a third sends nothing
	// more (no SIGKILL, which would skip the deploy's cleanup).
	m.Update(key("ctrl+c"))
	m.Update(key("ctrl+c"))
	m.Update(key("ctrl+c"))
	if m.stopping != 3 {
		t.Fatalf("stopping %d", m.stopping)
	}
}

func TestRenderFitsAndSaysWhatsHappening(t *testing.T) {
	work := t.TempDir()
	log := filepath.Join(work, "ios.log")
	_ = os.WriteFile(log, []byte("[20:44:01]: ▸ Compiling SerializableError.cpp\n"), 0o644)
	h := historyFrom("d t all iOS Archive 400", "d t all Lint - 120", "d t all Release - 10")
	m := newModel(work, "", h, 0)
	m.now = time.Unix(1300, 0)
	m.width, m.height = 90, 40
	m.snap = Snapshot{
		Ready: true, Mode: "all", Started: 1000,
		Stages:      []string{"Preflight", "Lint", "iOS", "Android", "Release"},
		StageStates: []string{"d", "r", "b", "b", "p"},
		CurStage:    1,
		Fg: Progress{Steps: []string{"go-test", "js-test"}, States: []string{"d", "r"}, Cur: -1,
			N: 1, Total: 2, Label: "checks", StepStart: 1250},
		Lanes: []Lane{
			{Name: "iOS", Alive: true, Log: log, Started: 1000, Progress: Progress{
				Steps: []string{"Check", "Archive", "Gate", "Upload"}, States: []string{"d", "r", "p", "p"},
				Cur: 1, N: 412, Total: 980, Label: "build steps", StepStart: 1100}},
			{Name: "Android", Started: 1000, Progress: Progress{
				Steps: []string{"Bundle", "Gate"}, States: []string{"f", "p"}, Cur: 0}},
		},
	}
	m.lastLines["iOS"] = lastLogLine(log)
	m.computeDisplay()
	out := ansi.Strip(m.render())
	for _, want := range []string{
		appSlug() + " deploy · all", "5:00", "min left", "%",
		"✓ Preflight", "● Lint", "◐ iOS",
		"1/2 checks",
		"Archive", "412/980 build steps",
		"▸ Compiling SerializableError.cpp",
		"✗ Android", "Bundle", "stopped",
		"ctrl+c stop the deploy",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("render lacks %q:\n%s", want, out)
		}
	}
	for i, line := range strings.Split(out, "\n") {
		if w := ansi.StringWidth(line); w > m.width {
			t.Errorf("line %d is %d wide, over %d: %q", i, w, m.width, line)
		}
	}

	// A question takes the lanes' place.
	m.ask(Question{ID: 1, Kind: "pick", Title: "Start the deploy?", Options: []string{"Start", "Cancel"}})
	out = ansi.Strip(m.render())
	if !strings.Contains(out, "Start the deploy?") || !strings.Contains(out, "› Start") || strings.Contains(out, "412/980") {
		t.Errorf("question view:\n%s", out)
	}
}

func TestRenderShortTerminalShedsDetailFirst(t *testing.T) {
	m := newModel(t.TempDir(), "", historyFrom("d t all iOS Archive 400"), 0)
	m.now = time.Unix(1300, 0)
	m.snap = Snapshot{
		Ready: true, Mode: "all", Started: 1000,
		Stages:      []string{"Preflight", "Lint", "iOS", "Android", "tvOS", "AndroidTV", "Desktop", "Release"},
		StageStates: []string{"d", "r", "b", "b", "b", "b", "b", "p"},
		CurStage:    1,
		Fg:          Progress{Steps: []string{"a", "b", "c"}, States: []string{"d", "r", "p"}, Cur: -1, N: 1, Total: 3, Label: "checks"},
	}
	for _, name := range []string{"iOS", "Android", "tvOS", "AndroidTV", "Desktop"} {
		m.snap.Lanes = append(m.snap.Lanes, Lane{Name: name, Alive: true, Progress: Progress{
			Steps: []string{"Archive", "Gate"}, States: []string{"r", "p"}, Cur: 0, StepStart: 1100}})
		m.lastLines[name] = "working on " + name
	}

	m.width, m.height = 100, 40
	m.computeDisplay()
	tall := ansi.Strip(m.render())
	if !strings.Contains(tall, "▸ working on iOS") {
		t.Fatalf("a tall terminal shows the lanes' log lines:\n%s", tall)
	}

	m.height = 14
	short := ansi.Strip(m.render())
	if n := strings.Count(short, "\n") + 1; n != m.height {
		t.Fatalf("the screen is %d rows in a %d-row terminal:\n%s", n, m.height, short)
	}
	if strings.Contains(short, "▸ working on") {
		t.Fatalf("the log lines go first:\n%s", short)
	}
	if !strings.Contains(short, "Desktop") || !strings.Contains(short, "1/3") {
		t.Fatalf("a short terminal still names every lane and the running stage:\n%s", short)
	}
}

func TestStoppingHidesTheQuestion(t *testing.T) {
	m := newModel(t.TempDir(), "", historyFrom(), 0)
	m.width, m.height = 100, 40
	m.snap = Snapshot{Ready: true, Mode: "all", Started: 1, Stages: []string{"Preflight"}, StageStates: []string{"r"}, CurStage: 0}
	m.ask(Question{ID: 1, Kind: "pick", Title: "Start the deploy?", Options: []string{"Start", "Cancel"}})
	m.Update(key("ctrl+c"))
	out := ansi.Strip(m.render())
	if strings.Contains(out, "Start the deploy?") || !strings.Contains(out, "Stopping") {
		t.Fatalf("after ctrl+c the question goes and the panel says it's stopping:\n%s", out)
	}
}

// TestPanelHoldsStill is the rule the panel is built on: its shape depends
// on the terminal and the set of lanes, never on what they're doing. Over a
// run of changing states the height, each lane's row and every bar's column
// stay put, and the overall percent never goes back.
func TestPanelHoldsStill(t *testing.T) {
	h := historyFrom(
		"d t all Lint - 120", "d t all Infra Apply 60", "d t all Web Build 20", "d t all Release - 10",
		"d t all iOS Archive 300", "d t all iOS Upload 60", "d t all Android Bundle 100",
	)
	m := newModel(t.TempDir(), "", h, 0)
	m.width, m.height = 110, 40
	plan := map[string][]string{
		"Preflight": {"Git", "Options", "Tools", "AWS", "Stores", "Version", "Plan", "Confirm"},
		"Lint":      {"go-types", "js-lint", "js-types", "js-format", "web-build", "desktop-build", "js-test", "go-test", "go-vet", "go-build", "go-fmt", "go-dynamolocal", "deploy-tui", "tf-fmt", "tf-validate", "tf-test"},
		"Infra":     {"Apply"},
		"iOS":       {"Check", "Pods", "Archive", "Gate", "Upload"},
		"Android":   {"Version", "Check", "Bundle", "Verify", "Gate", "Upload"},
	}
	stages := []string{"Preflight", "Lint", "Infra", "Web", "iOS", "Android", "Release"}
	lane := func(name string, steps []string, cur int, n, total int, ok, alive bool) Lane {
		st := make([]string, len(steps))
		for i := range st {
			switch {
			case ok || i < cur:
				st[i] = "d"
			case i == cur:
				st[i] = "r"
			default:
				st[i] = "p"
			}
		}
		return Lane{Name: name, OK: ok, Alive: alive, Started: 1000,
			Progress: Progress{Steps: steps, States: st, Cur: cur, N: n, Total: total, Label: "build steps", StepStart: 1000}}
	}
	type moment struct {
		stage int
		fg    Progress
		ios   Lane
		droid Lane
		log   string
	}
	lintSteps := plan["Lint"]
	lintStates := func(done int) []string {
		st := make([]string, len(lintSteps))
		for i := range st {
			st[i] = map[bool]string{true: "d", false: "p"}[i < done]
		}
		return st
	}
	moments := []moment{
		{1, Progress{Steps: lintSteps, States: lintStates(2), Cur: -1, N: 2, Total: 16, Label: "checks"},
			lane("iOS", plan["iOS"], 2, 100, 980, false, true), lane("Android", plan["Android"], 2, 0, 0, false, true), ""},
		{1, Progress{Steps: lintSteps, States: lintStates(9), Cur: -1, N: 9, Total: 16, Label: "checks"},
			lane("iOS", plan["iOS"], 2, 600, 980, false, true), lane("Android", plan["Android"], 4, 0, 0, false, true), "Compiling a much longer file name than before.swift"},
		{2, Progress{Steps: []string{"Apply"}, States: []string{"r"}, Cur: 0, N: 40, Total: 112, Label: "resources"},
			lane("iOS", plan["iOS"], 3, 0, 0, false, true), lane("Android", plan["Android"], 4, 0, 0, false, true), "x"},
		{2, Progress{Steps: []string{"Apply"}, States: []string{"r"}, Cur: 0, N: 100, Total: 112, Label: "resources"},
			lane("iOS", plan["iOS"], 4, 0, 0, false, true), lane("Android", plan["Android"], 0, 0, 0, false, false), ""},
		{3, Progress{Steps: []string{"Build", "Upload", "Invalidate"}, States: []string{"d", "r", "p"}, Cur: 1},
			lane("iOS", plan["iOS"], 4, 0, 0, true, false), lane("Android", plan["Android"], 0, 0, 0, false, false), ""},
	}
	var height, iosRow, barCol int
	lastPct := -1
	for i, mo := range moments {
		states := []string{"d", "p", "p", "p", "b", "b", "p"}
		for j := 0; j < mo.stage; j++ {
			states[j] = "d"
		}
		states[mo.stage] = "r"
		m.now = time.Unix(int64(1100+i*60), 0)
		m.snap = Snapshot{Ready: true, Mode: "all", Started: 1000, Stages: stages, StageStates: states,
			CurStage: mo.stage, Fg: mo.fg, Lanes: []Lane{mo.ios, mo.droid}, Plan: plan}
		m.lastLines["iOS"] = mo.log
		m.computeDisplay()
		lines := strings.Split(ansi.Strip(m.render()), "\n")
		// A block's first row carries its name; its bar is on the row
		// under it.
		row, fgRow := -1, -1
		for r, l := range lines {
			if strings.HasPrefix(l, "│ ◐ iOS") || strings.HasPrefix(l, "│ ✓ iOS") {
				row = r
			}
			if strings.HasPrefix(l, "│ ● ") {
				fgRow = r
			}
		}
		if row < 0 || fgRow < 0 {
			t.Fatalf("moment %d: no iOS or stage block:\n%s", i, strings.Join(lines, "\n"))
		}
		col := strings.Index(lines[row+1], "[")
		fgCol := strings.Index(lines[fgRow+1], "[")
		pct := -1
		for _, l := range lines {
			if strings.Contains(l, "%") && strings.Contains(l, "█") || strings.Contains(l, "%") && strings.Contains(l, "░") {
				f := strings.Fields(strings.Trim(l, "│ "))
				fmt.Sscanf(f[len(f)-1], "%d%%", &pct)
			}
		}
		if i == 0 {
			height, iosRow, barCol = len(lines), row, col
		}
		if len(lines) != height || row != iosRow || col != barCol || fgCol != barCol {
			t.Fatalf("moment %d moved: height %d (was %d), iOS row %d (was %d), bar column %d / stage bar %d (was %d):\n%s",
				i, len(lines), height, row, iosRow, col, fgCol, barCol, strings.Join(lines, "\n"))
		}
		if pct < lastPct {
			t.Fatalf("moment %d: the overall percent went back from %d to %d", i, lastPct, pct)
		}
		lastPct = max(lastPct, pct)
	}
}

func TestThreeBoxes(t *testing.T) {
	m := newModel(t.TempDir(), "", historyFrom(), 0)
	m.width, m.height = 120, 30
	m.snap = Snapshot{Ready: true, Mode: "all", Started: 1000,
		Stages: []string{"Preflight", "Lint", "iOS"}, StageStates: []string{"d", "r", "b"}, CurStage: 1,
		Fg:    Progress{Steps: []string{"go-test"}, States: []string{"r"}, Cur: -1, N: 0, Total: 1, Label: "checks"},
		Lanes: []Lane{{Name: "iOS", Alive: true, Progress: Progress{Steps: []string{"Archive"}, States: []string{"r"}, Cur: 0}}},
	}
	m.now = time.Unix(1060, 0)
	for i := 1; i <= 100; i++ {
		m.addOutput(fmt.Sprintf("line %d", i))
	}
	m.computeDisplay()
	lines := strings.Split(ansi.Strip(m.render()), "\n")
	if len(lines) != m.height {
		t.Fatalf("the screen is %d rows, want %d", len(lines), m.height)
	}
	for i, l := range lines {
		if w := ansi.StringWidth(l); w != m.width {
			t.Fatalf("row %d is %d wide, want %d: %q", i, w, m.width, l)
		}
	}
	screen := strings.Join(lines, "\n")
	for _, want := range []string{"╭─ Steps", "╭─ Output", "╭─ " + appSlug() + " deploy · all", "line 100", "◐ iOS", "● Lint", "✓ Preflight", "1:00"} {
		if !strings.Contains(screen, want) {
			t.Errorf("the screen lacks %q:\n%s", want, screen)
		}
	}
	if strings.Contains(screen, "line 1\n") {
		t.Error("the output box shows the newest lines, not the first")
	}

	// A question takes the steps box; the output stays.
	m.ask(Question{ID: 1, Kind: "pick", Title: "Start the deploy?", Options: []string{"Start", "Cancel"}})
	screen = ansi.Strip(m.render())
	if !strings.Contains(screen, "╭─ Your answer") || !strings.Contains(screen, "› Start") ||
		!strings.Contains(screen, "line 100") || strings.Contains(screen, "│ ◐ iOS") {
		t.Fatalf("question screen:\n%s", screen)
	}
	m.answer("0")

	// Scrolled back, the box keeps its lines as new ones arrive.
	m.Update(tea.KeyPressMsg{Code: tea.KeyPgUp})
	body := func() string {
		// Below the top borders, whose note counts the lines up.
		rows := strings.Split(ansi.Strip(m.render()), "\n")
		return strings.Join(rows[1:], "\n")
	}
	before := body()
	m.addOutput("line 101")
	after := body()
	if before != after || strings.Contains(after, "line 101") || !strings.Contains(ansi.Strip(m.render()), "end to follow") {
		t.Fatalf("a scrolled-back output box moved:\n%s", after)
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyEnd})
	if !strings.Contains(ansi.Strip(m.render()), "line 101") {
		t.Fatal("End goes back to following the output")
	}
}

func TestHangupClosesWithoutQ(t *testing.T) {
	m := newModel(t.TempDir(), "", historyFrom(), 0)
	m.Update(goneMsg{})
	if _, cmd := m.Update(exitMsg{code: 129}); cmd == nil {
		t.Fatal("after a hangup the screen must close when the deploy does: nobody can press q")
	}
}

func TestFinishedScreenWaitsForQ(t *testing.T) {
	m := newModel(t.TempDir(), "", historyFrom(), 0)
	m.Update(exitMsg{code: 0})
	if !m.done {
		t.Fatal("not done after the deploy exits")
	}
	if _, cmd := m.Update(key("x")); cmd != nil {
		t.Fatal("another key closes the finished screen")
	}
	if _, cmd := m.Update(key("q")); cmd == nil {
		t.Fatal("q doesn't close it")
	}
}

func TestOutputPages(t *testing.T) {
	work := t.TempDir()
	write := func(name, text string) string {
		path := filepath.Join(work, name)
		_ = os.WriteFile(path, []byte(text), 0o644)
		return path
	}
	iosLog := write("ios.log", "▸ Compiling A.swift\n▸ Compiling B.swift\n")
	threads := []ThreadInfo{
		{Key: "lint-go-types", Title: "go-types", Log: write("go-types.log", "ok\n"), State: "d", Started: 1010},
		{Key: "lint-js-test", Title: "js-test", Log: write("js-test.log", "PASS src/a.test.ts\n"), State: "r", Started: 1011},
		{Key: "lint-go-vet", Title: "go-vet", Log: write("go-vet.log", "vet: bad thing\n"), State: "f", Started: 1012},
		{Key: "lint-tf-fmt", Title: "tf-fmt", Log: write("tf-fmt.log", ""), State: "s", Started: 1013},
	}
	m := newModel(work, "", historyFrom(), 0)
	m.width, m.height = 120, 30
	m.now = time.Unix(1100, 0)
	m.snap = Snapshot{Ready: true, Mode: "all", Started: 1000,
		Stages: []string{"Preflight", "Lint", "iOS", "Android"}, StageStates: []string{"d", "r", "b", "b"}, CurStage: 1,
		Fg: Progress{Steps: []string{"go-types", "js-test", "go-vet", "tf-fmt"}, States: []string{"d", "r", "f", "s"}, Cur: -1},
		Lanes: []Lane{
			{Name: "iOS", Alive: true, Log: iosLog, Started: 1005, Progress: Progress{Steps: []string{"Archive"}, States: []string{"r"}, Cur: 0}},
			{Name: "Android", OK: true, Log: write("android.log", "done\n"), Started: 1006},
		},
		Threads: threads,
	}
	m.addOutput("━━ Lint")
	m.updateThreads()
	titles := func() string {
		var out []string
		for _, p := range m.pages() {
			out = append(out, p.title)
		}
		return strings.Join(out, " ")
	}
	// The summary first, then running and failed threads in the order they
	// started; finished and skipped ones (go-types, tf-fmt, the Android lane)
	// have no page.
	if got := titles(); got != "Summary iOS js-test go-vet" {
		t.Fatalf("pages: %s", got)
	}
	// The stage's block shows the newest running thread's latest line.
	if !strings.Contains(ansi.Strip(m.render()), "▸ PASS src/a.test.ts") {
		t.Fatalf("the stage's latest line:\n%s", ansi.Strip(m.render()))
	}

	screen := ansi.Strip(m.render())
	if !strings.Contains(screen, " Summary ") || !strings.Contains(screen, "━━ Lint") {
		t.Fatalf("the summary's page is first:\n%s", screen)
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	screen = ansi.Strip(m.render())
	if !strings.Contains(screen, "▸ Compiling B.swift") || strings.Contains(screen, "━━ Lint") {
		t.Fatalf("→ shows the iOS lane's log:\n%s", screen)
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	m.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	if !strings.Contains(ansi.Strip(m.render()), "vet: bad thing") {
		t.Fatal("the failed check's page shows its log")
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	if m.page != "" {
		t.Fatalf("→ past the last page wraps to the summary, got %q", m.page)
	}

	// The page shown stays while it's shown, though it has finished.
	m.Update(tea.KeyPressMsg{Code: tea.KeyRight})
	m.snap.Lanes[0] = Lane{Name: "iOS", OK: true, Log: iosLog, Started: 1005}
	m.updateThreads()
	if m.page != "lane:iOS" || titles() != "Summary iOS js-test go-vet" {
		t.Fatalf("the finished page shown stays: page %q, pages %s", m.page, titles())
	}
	m.Update(tea.KeyPressMsg{Code: tea.KeyLeft})
	if got := titles(); got != "Summary js-test go-vet" {
		t.Fatalf("once left, a finished page goes: %s", got)
	}

	// A thread that ends drops off; a failed one stays.
	m.snap.Threads[1].State = "d"
	m.updateThreads()
	if got := titles(); got != "Summary go-vet" {
		t.Fatalf("after js-test ends: %s", got)
	}
}

// runThread runs lib/tracker.sh's thread_run on a command in a fresh $WORK,
// under the deploy UI or not; it returns the summary bash printed, the
// thread's log, and its registered state.
func runThread(t *testing.T, tui bool, command string) (summary, log, state string) {
	t.Helper()
	work := t.TempDir()
	tracker, _ := filepath.Abs("../lib/tracker.sh")
	prompt, _ := filepath.Abs("../lib/prompt.sh")
	script := `set -euo pipefail
die() { echo "$*" >&2; exit 1; }
source "$TRACKER"; source "$PROMPT"
S="$WORK/status"; mkdir -p "$S"
` + command + `
echo "AFTER rc=$rc"`
	cmd := exec.Command("bash", "-c", script)
	cmd.Env = append(cleanEnv(), "TRACKER="+tracker, "PROMPT="+prompt, "WORK="+work)
	if tui {
		cmd.Env = append(cmd.Env, "DEPLOY_UI=tui")
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("bash: %v\n%s", err, out)
	}
	b, _ := os.ReadFile(filepath.Join(work, "threads", "k.log"))
	st, _ := os.ReadFile(filepath.Join(work, "status", "threads", "k", "state"))
	return ansi.Strip(string(out)), string(b), strings.TrimSpace(string(st))
}

func TestThreadRun(t *testing.T) {
	// Under the UI the output goes to the thread's log only; a failure puts
	// its last lines in the summary.
	summary, log, state := runThread(t, true, `rc=0; thread_run k "Build" bash -c 'echo compiling; echo broken >&2; exit 3' || rc=$?`)
	if !strings.Contains(log, "compiling") || !strings.Contains(log, "broken") || state != "f" {
		t.Fatalf("log %q, state %q", log, state)
	}
	if !strings.Contains(summary, "Build failed") || !strings.Contains(summary, "│ broken") ||
		strings.Contains(summary, "│ compiling\n  ✗") || !strings.Contains(summary, "AFTER rc=3") {
		t.Fatalf("summary:\n%s", summary)
	}
	if strings.Count(summary, "compiling") != 1 {
		t.Fatalf("under the UI a thread's output reaches the summary only in a failure's tail:\n%s", summary)
	}

	// A die inside a thread ends the thread, not the deploy, and says why.
	summary, _, state = runThread(t, true, `f() { echo before; die "TestFlight already has a newer build"; echo after; }
rc=0; thread_run k "TestFlight check" f || rc=$?`)
	if state != "f" || !strings.Contains(summary, "│ TestFlight already has a newer build") ||
		strings.Contains(summary, "│ after") || !strings.Contains(summary, "AFTER rc=1") {
		t.Fatalf("a die in a thread:\n%s", summary)
	}

	// A success: done, one line in the summary, the output in the log.
	summary, log, state = runThread(t, true, `rc=0; thread_run k "Plan" bash -c 'echo refreshing state' || rc=$?`)
	if state != "d" || !strings.Contains(log, "refreshing state") || strings.Contains(summary, "refreshing state") ||
		!strings.Contains(summary, "✓ Plan") {
		t.Fatalf("a success: state %q, summary:\n%s", state, summary)
	}

	// Without the UI the output also goes to the terminal, as before.
	summary, log, state = runThread(t, false, `rc=0; thread_run k "Plan" bash -c 'echo refreshing state' || rc=$?`)
	if state != "d" || !strings.Contains(log, "refreshing state") || !strings.Contains(summary, "refreshing state") {
		t.Fatalf("plain: state %q, summary:\n%s", state, summary)
	}
}

func TestKeepRunFolders(t *testing.T) {
	t.Setenv("DEPLOY_KEEP_LOGS", "")
	if got := keepRunFolders(); got != 5 {
		t.Fatalf("no setting: %d, want 5", got)
	}
	t.Setenv("DEPLOY_KEEP_LOGS", `"3"`)
	if got := keepRunFolders(); got != 3 {
		t.Fatalf("quoted: %d, want 3", got)
	}
	t.Setenv("DEPLOY_KEEP_LOGS", "8")
	if got := keepRunFolders(); got != 8 {
		t.Fatalf("set: %d, want 8", got)
	}
	t.Setenv("DEPLOY_KEEP_LOGS", "0")
	if got := keepRunFolders(); got != 5 {
		t.Fatalf("a nonsense value falls back: %d, want 5", got)
	}
}

func finishedModel(t *testing.T, code int, final, style string) *model {
	t.Helper()
	m := newModel(t.TempDir(), "", historyFrom(), 0)
	m.width, m.height = 120, 34
	m.runDir = "/tmp/demo-run"
	m.snap = Snapshot{Ready: true, Mode: "all", Started: 1000, Final: final, FinalStyle: style,
		Stages:      []string{"Preflight", "Lint", "iOS", "Desktop", "Release"},
		StageStates: []string{"d", "d", "d", "f", "p"}, CurStage: -1,
		Lanes: []Lane{
			{Name: "iOS", OK: true, Result: "0.19.3 (166) uploaded to TestFlight", Started: 1000},
			{Name: "Desktop", Log: "/repo/apps/desktop/build/deploy-desktop.log", Started: 1000,
				Progress: Progress{Steps: []string{"Package", "Upload"}, States: []string{"d", "f"}, Cur: 1}},
		},
	}
	m.done, m.exitCode = true, code
	m.finishedAt = time.Unix(1000+23*60+41, 0)
	return m
}

func TestFinishedPanel(t *testing.T) {
	m := finishedModel(t, 0, "Deployed 0.19.3 (166).", "32")
	screen := ansi.Strip(m.render())
	for _, want := range []string{"╭─ Finished", "✓ DEPLOYED   in 23:41 · finished", "Deployed 0.19.3 (166).",
		"✓ iOS", "uploaded to TestFlight", "Every log of this run: /tmp/demo-run/", "q to close", "took 23:41"} {
		if !strings.Contains(screen, want) {
			t.Errorf("deployed: lacks %q:\n%s", want, screen)
		}
	}
	if v := m.View(); v.WindowTitle != "✓ "+appSlug()+" deploy: deployed" {
		t.Errorf("tab title %q", v.WindowTitle)
	}

	m = finishedModel(t, 1, "Failed: Desktop. The other stores carried on; Release didn't run.", "1;31")
	screen = ansi.Strip(m.render())
	for _, want := range []string{"✗ FAILED", "✗ Desktop", "stopped at Upload", "○ Release", "not reached"} {
		if !strings.Contains(screen, want) {
			t.Errorf("failed: lacks %q:\n%s", want, screen)
		}
	}
	// The borders take the result's colour: red here, so not the dim of a
	// running deploy.
	if raw := m.render(); !strings.Contains(raw, lipgloss.NewStyle().Foreground(lipgloss.Red).Render("╭─")) {
		t.Error("a failed run's borders aren't red")
	}

	m = finishedModel(t, 130, "Stopped (ctrl+c).", "33")
	if screen = ansi.Strip(m.render()); !strings.Contains(screen, "■ STOPPED") {
		t.Errorf("stopped:\n%s", screen)
	}
}

func TestNotifiesOnceWhenItEnds(t *testing.T) {
	work := t.TempDir()
	st := filepath.Join(work, "status")
	put(t, st, "stages", "Preflight")
	put(t, st, "started", "1000")
	put(t, st, "stage_states", "d")
	put(t, st, "final", "Deployed 0.19.3 (166).")
	put(t, st, "final_style", "32")
	m := newModel(work, "", historyFrom(), 0)
	var got []string
	m.notify = func(headline, message string) { got = append(got, headline+": "+message) }
	_, cmd := m.Update(exitMsg{code: 0})
	if cmd == nil {
		t.Fatal("no notification when the deploy ends")
	}
	cmd()
	if len(got) != 1 || got[0] != "DEPLOYED: Deployed 0.19.3 (166)." {
		t.Fatalf("notification: %q", got)
	}

	// After a hangup nobody is there: no notification, the screen closes.
	m = newModel(t.TempDir(), "", historyFrom(), 0)
	m.notify = func(string, string) { t.Fatal("notified after a hangup") }
	m.Update(goneMsg{})
	if _, cmd := m.Update(exitMsg{code: 129}); cmd == nil {
		t.Fatal("the screen must close after a hangup")
	}
}

func TestGroupedChecklist(t *testing.T) {
	// API + Infra; Web (app, www); Mobile (ios, android); Release.
	q := Question{Kind: "many", Options: []string{"infra", "Web", "app", "www", "Mobile", "ios", "android", "release"},
		Parents: []string{"-", "h", "1", "1", "h", "4", "4", "-"}}
	picks := []bool{true, false, true, false, false, false, false, true}
	q.syncGroups(picks)
	if !picks[1] || picks[4] {
		t.Fatalf("sync: a group is ticked when any member is: %v", picks)
	}
	if got := q.box(picks, 1); got != "[~] " {
		t.Fatalf("partly ticked group: %q", got)
	}
	if got := q.box(picks, 2); got != "    [x] " {
		t.Fatalf("member: %q", got)
	}
	q.toggle(picks, 1) // not all ticked: tick them all
	if !picks[2] || !picks[3] || q.box(picks, 1) != "[x] " {
		t.Fatalf("group tick: %v", picks)
	}
	q.toggle(picks, 1) // all ticked: untick them all
	if picks[1] || picks[2] || picks[3] {
		t.Fatalf("group untick: %v", picks)
	}
	q.toggle(picks, 5)
	if !picks[4] || !picks[5] || picks[6] || q.box(picks, 4) != "[~] " {
		t.Fatalf("member tick: %v", picks)
	}
	if q.box(picks, 0) != "[x] " || q.isMember(0) || q.isGroup(0) {
		t.Fatal("an ungrouped option is neither")
	}
}

func TestGroupedChecklistWithBash(t *testing.T) {
	q, out := askBash(t, `PICK_PARENT=(- h 1 1 -); PICK_DEFAULTS=(1 1 1 0 1); pick_many infra Web app www release; echo "PICKS=${PICKS[*]}"`,
		"1 0 0 1 0")
	if strings.Join(q.Parents, " ") != "- h 1 1 -" || q.Default != "1 1 1 0 1" {
		t.Fatalf("parents and default: %+v", q)
	}
	// The answer's group bit is recomputed from its members (www ticked).
	if !strings.Contains(out, "PICKS=1 1 0 1 0") {
		t.Fatalf("grouped answer: %q", out)
	}
}
