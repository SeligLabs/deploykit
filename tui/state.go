package main

// The deploy's state, as deploykit lib/tracker.sh writes it under
// $WORK/status: one small file per value, each replaced atomically (written
// beside, then moved), so a read never sees half a value.
//
//	stages, mode, started, cur_stage, stage_states    the run
//	steps, step_states, cur_step, step_start           the running stage
//	n, total, label, ln, lt, label2                    its step's progress
//	final, final_style                                 the last word
//	plan                                               "<stage> <step> ..."
//	lanes_planned                                      the lanes about to start
//	threads/<key>/{title,log,state,started,ended}     each thread (lib/tracker.sh)
//	bg/<lane>/...                                      each background lane:
//	    the same step and progress files, plus started, log, pid and ok
//
// States are one letter: p pending, r running, b running in the
// background, d done, f failed, s skipped.

import (
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

// Progress is a stage's or a lane's steps and the running step's progress.
type Progress struct {
	Steps     []string
	States    []string
	Cur       int // index into Steps, -1 when no single step runs (Lint)
	N, Total  int // a count when Total > 0: "412/980 build steps"
	Label     string
	LN, LT    int // a second count: "3/97 lambdas"
	Label2    string
	StepStart int64
}

// State is one step's state, "p" past the end.
func (p Progress) State(i int) string {
	if i < 0 || i >= len(p.States) || p.States[i] == "" {
		return "p"
	}
	return p.States[i]
}

// Step is the running step's name, or "".
func (p Progress) Step() string {
	if p.Cur >= 0 && p.Cur < len(p.Steps) {
		return p.Steps[p.Cur]
	}
	return ""
}

// Lane is a stage running in the background (a store build, the watch
// tests): a subshell with a state directory of its own.
type Lane struct {
	Name string
	Progress
	Started int64
	Log     string // where its output goes, absolute
	Pid     int
	OK      bool // finished, and well
	Alive   bool
	Pending bool   // announced (lanes_planned) but not started yet
	Result  string // what it handed back ($WORK/<lane>-result), when it has
}

// Snapshot is the whole run at one moment.
type Snapshot struct {
	Mode        string
	Stages      []string
	StageStates []string
	CurStage    int
	Started     int64
	Fg          Progress // the running foreground stage
	Final       string
	FinalStyle  string // an SGR code: 32 green, 33 yellow, 1;31 red
	Lanes       []Lane // in Stages order
	Ready       bool   // the tracker has started
	// Plan is every stage's steps, written once when the tracker starts,
	// so the panel can be laid out for the longest and the stages to come
	// estimated step by step.
	Plan map[string][]string
	// Threads is every piece of work with an output of its own that the
	// deploy has started (the API build, the plan, each Lint check, ...),
	// lanes aside, in the order they started.
	Threads []ThreadInfo
}

// ThreadInfo is a thread as the tracker registered it.
type ThreadInfo struct {
	Key, Title, Log, State string
	Started, Ended         int64
}

// StageState is one stage's state.
func (s Snapshot) StageState(i int) string {
	if i < 0 || i >= len(s.StageStates) || s.StageStates[i] == "" {
		return "p"
	}
	return s.StageStates[i]
}

// StageStateOf is a stage's state by name.
func (s Snapshot) StageStateOf(name string) string {
	for i, n := range s.Stages {
		if n == name {
			return s.StageState(i)
		}
	}
	return "p"
}

// Lane is a lane by name.
func (s Snapshot) Lane(name string) (Lane, bool) {
	for _, l := range s.Lanes {
		if l.Name == name {
			return l, true
		}
	}
	return Lane{}, false
}

func readValue(dir, key string) string {
	b, err := os.ReadFile(filepath.Join(dir, key))
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(b), "\n")
}

func readInt(dir, key string, fallback int) int {
	v, err := strconv.Atoi(strings.TrimSpace(readValue(dir, key)))
	if err != nil {
		return fallback
	}
	return v
}

func readInt64(dir, key string) int64 {
	v, _ := strconv.ParseInt(strings.TrimSpace(readValue(dir, key)), 10, 64)
	return v
}

func readProgress(dir string) Progress {
	return Progress{
		Steps:     strings.Fields(readValue(dir, "steps")),
		States:    strings.Fields(readValue(dir, "step_states")),
		Cur:       readInt(dir, "cur_step", -1),
		N:         readInt(dir, "n", 0),
		Total:     readInt(dir, "total", 0),
		Label:     readValue(dir, "label"),
		LN:        readInt(dir, "ln", 0),
		LT:        readInt(dir, "lt", 0),
		Label2:    readValue(dir, "label2"),
		StepStart: readInt64(dir, "step_start"),
	}
}

// alive reports whether a process exists.
func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// ReadSnapshot reads $WORK/status. A run that hasn't started its tracker
// yet reads as not Ready.
func ReadSnapshot(work string) Snapshot {
	dir := filepath.Join(work, "status")
	s := Snapshot{
		Mode:        readValue(dir, "mode"),
		Stages:      strings.Fields(readValue(dir, "stages")),
		StageStates: strings.Fields(readValue(dir, "stage_states")),
		CurStage:    readInt(dir, "cur_stage", -1),
		Started:     readInt64(dir, "started"),
		Fg:          readProgress(dir),
		Final:       readValue(dir, "final"),
		FinalStyle:  readValue(dir, "final_style"),
	}
	s.Ready = s.Started > 0 && len(s.Stages) > 0
	s.Plan = map[string][]string{}
	for _, line := range strings.Split(readValue(dir, "plan"), "\n") {
		if f := strings.Fields(line); len(f) > 0 {
			s.Plan[f[0]] = f[1:]
		}
	}
	if entries, err := os.ReadDir(filepath.Join(dir, "threads")); err == nil {
		for _, e := range entries {
			td := filepath.Join(dir, "threads", e.Name())
			t := ThreadInfo{Key: e.Name(), Title: readValue(td, "title"), Log: readValue(td, "log"),
				State: readValue(td, "state"), Started: readInt64(td, "started"), Ended: readInt64(td, "ended")}
			if t.Title != "" {
				s.Threads = append(s.Threads, t)
			}
		}
		sort.SliceStable(s.Threads, func(i, j int) bool { return s.Threads[i].Started < s.Threads[j].Started })
	}
	planned := map[string]bool{}
	for _, name := range strings.Fields(readValue(dir, "lanes_planned")) {
		planned[name] = true
	}
	for _, name := range s.Stages {
		ld := filepath.Join(dir, "bg", name)
		if _, err := os.Stat(ld); err != nil {
			if planned[name] {
				s.Lanes = append(s.Lanes, Lane{Name: name, Pending: true})
			}
			continue
		}
		l := Lane{
			Name:     name,
			Progress: readProgress(ld),
			Started:  readInt64(ld, "started"),
			Log:      readValue(ld, "log"),
			Pid:      readInt(ld, "pid", 0),
		}
		_, err := os.Stat(filepath.Join(ld, "ok"))
		l.OK = err == nil
		// bg_start writes the pid just after the folder: no pid yet is a
		// lane starting, not one that stopped.
		l.Alive = !l.OK && (l.Pid == 0 || alive(l.Pid))
		l.Result = readValue(work, strings.ToLower(name)+"-result")
		s.Lanes = append(s.Lanes, l)
	}
	return s
}
