package main

// Estimates from past runs. Every deploy appends "<date> <time> <mode>
// <stage> <step> <seconds>" to ~/.cache/<APP_SLUG>/deploy-timings for each step,
// and "-" as the step for a stage's whole time (lib/tracker.sh timing). The
// median of the last few runs of a step gives a step with no count of its
// own a bar, and the run an overall bar and a time left.

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// keepRuns is how many recent samples of a step count: enough to ride out
// one odd run, few enough to follow a step that got faster.
const keepRuns = 7

// waits are steps that time a person or another stage, not work.
var waits = map[string]bool{"Gate": true, "Confirm": true, "Options": true, "Notes": true}

// History is past step times by mode, stage and step.
type History struct {
	samples map[string][]float64
}

func historyKey(mode, stage, step string) string { return mode + "\x00" + stage + "\x00" + step }

// TimingsPath is where lib/tracker.sh writes the times.
func TimingsPath() string {
	base := os.Getenv("XDG_CACHE_HOME")
	if base == "" {
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, ".cache")
	}
	return filepath.Join(base, appSlug(), "deploy-timings")
}

// appSlug names the app in paths and the title: APP_SLUG, which the engine
// exports, else the app.slug of the package.json in the working directory
// (the repo root, where yarn runs it), else "app".
func appSlug() string {
	if s := strings.TrimSpace(os.Getenv("APP_SLUG")); s != "" {
		return s
	}
	var pkg struct {
		App struct {
			Slug string `json:"slug"`
		} `json:"app"`
	}
	if b, err := os.ReadFile("package.json"); err == nil && json.Unmarshal(b, &pkg) == nil && pkg.App.Slug != "" {
		return pkg.App.Slug
	}
	return "app"
}

// LoadHistory reads the timings file; a missing one is an empty history.
func LoadHistory(path string) *History {
	h := &History{samples: map[string][]float64{}}
	f, err := os.Open(path)
	if err != nil {
		return h
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		h.add(sc.Text())
	}
	return h
}

func (h *History) add(line string) {
	fields := strings.Fields(line)
	if len(fields) != 6 {
		return
	}
	mode, stage, step := fields[2], fields[3], fields[4]
	secs, err := strconv.ParseFloat(fields[5], 64)
	if err != nil || secs < 0 {
		return
	}
	for _, m := range []string{mode, "*"} {
		k := historyKey(m, stage, step)
		v := append(h.samples[k], secs)
		if len(v) > keepRuns {
			v = v[len(v)-keepRuns:]
		}
		h.samples[k] = v
	}
}

// Est is the median time of a stage's step ("-" for the whole stage), from
// runs of this mode when there are any, else from any mode.
func (h *History) Est(mode, stage, step string) (float64, bool) {
	if waits[step] {
		return 0, false
	}
	for _, m := range []string{mode, "*"} {
		if v := h.samples[historyKey(m, stage, step)]; len(v) > 0 {
			return median(v), true
		}
	}
	return 0, false
}

func median(v []float64) float64 {
	s := append([]float64(nil), v...)
	sort.Float64s(s)
	n := len(s)
	if n%2 == 1 {
		return s[n/2]
	}
	return (s[n/2-1] + s[n/2]) / 2
}

// StepRemaining is how long the running step of p has left, and its
// fraction done (-1 when there is nothing to go on). A count beats history:
// its rate so far. A step past its usual time is given a tenth of it more,
// so the bar slows near the end instead of sitting full.
func (h *History) StepRemaining(mode, stage string, p Progress, now int64) (left, frac float64, ok bool) {
	step := p.Step()
	if step == "" {
		// Steps running side by side (Lint's checks): the count says how far.
		if p.Total > 0 {
			return 0, minFloat(float64(p.N)/float64(p.Total), 1), false
		}
		return 0, -1, false
	}
	elapsed := float64(now - p.StepStart)
	if elapsed < 0 {
		elapsed = 0
	}
	if p.Total > 0 {
		frac = float64(p.N) / float64(p.Total)
		if frac > 1 {
			frac = 1
		}
		if p.N > 0 && elapsed > 0 {
			return elapsed * float64(p.Total-p.N) / float64(p.N), frac, true
		}
		if est, ok := h.Est(mode, stage, step); ok {
			return est, frac, true
		}
		return 0, frac, false
	}
	est, ok := h.Est(mode, stage, step)
	if !ok || est <= 0 {
		return 0, -1, false
	}
	left = est - elapsed
	if left < est/10 {
		left = est / 10
	}
	return left, elapsed / (elapsed + left), true
}

// Remaining is what p has left: the running step plus every pending one,
// split at a Gate step (a lane's build before it, its upload after).
func (h *History) Remaining(mode, stage string, p Progress, now int64) (before, after float64) {
	pastGate := false
	for i, step := range p.Steps {
		if step == "Gate" {
			if p.State(i) != "p" && p.State(i) != "r" {
				// Through the gate already: everything left is upload.
				before, after = 0, before+after
			}
			pastGate = true
			continue
		}
		var t float64
		switch p.State(i) {
		case "r", "b":
			if i == p.Cur {
				t, _, _ = h.StepRemaining(mode, stage, p, now)
			} else if est, ok := h.Est(mode, stage, step); ok {
				// Running beside others (Lint's checks): half its usual time.
				t = est / 2
			}
		case "p":
			t, _ = h.Est(mode, stage, step)
		}
		if pastGate {
			after += t
		} else {
			before += t
		}
	}
	return before, after
}

func hasStep(p Progress, name string) bool {
	for _, s := range p.Steps {
		if s == name {
			return true
		}
	}
	return false
}

// Overall is the run's time left. The foreground runs its stages in order;
// each lane builds beside it from the start; a lane with a Gate uploads only
// once the foreground has passed Web; the stages after the lanes wait for
// all of them. ok is false until there is any history to go on.
func (h *History) Overall(s Snapshot, now int64) (left float64, ok bool) {
	lanes := map[string]Lane{}
	for _, l := range s.Lanes {
		if !l.Pending {
			lanes[l.Name] = l
		}
	}
	var t, gateBase, laneEnd float64
	inLanes := false
	known := false
	for i, name := range s.Stages {
		state := s.StageState(i)
		l, isLane := lanes[name]
		gated := isLane && hasStep(l.Progress, "Gate")
		if gated {
			if !inLanes {
				inLanes, gateBase, laneEnd = true, t, t
			}
			if l.OK || state == "d" || state == "s" || state == "f" {
				continue
			}
			before, after := h.Remaining(s.Mode, name, l.Progress, now)
			if before+after > 0 {
				known = true
			}
			end := before
			if gateBase > end {
				end = gateBase
			}
			end += after
			if end > laneEnd {
				laneEnd = end
			}
			continue
		}
		if inLanes {
			if laneEnd > t {
				t = laneEnd
			}
			inLanes = false
		}
		switch {
		case isLane && !l.OK && state != "d" && state != "s" && state != "f":
			// A lane the foreground waits for (the watch tests).
			before, after := h.Remaining(s.Mode, name, l.Progress, now)
			if before+after > 0 {
				known = true
			}
			if before+after > t {
				t = before + after
			}
		case state == "r" && i == s.CurStage:
			before, after := h.Remaining(s.Mode, name, s.Fg, now)
			if before+after > 0 {
				known = true
			}
			t += before + after
		case state == "p":
			// Step by step when the plan names them; the stage's whole time
			// otherwise.
			var sum float64
			found := false
			for _, step := range s.Plan[name] {
				if est, ok := h.Est(s.Mode, name, step); ok {
					sum += est
					found = true
				}
			}
			if !found {
				sum, found = h.Est(s.Mode, name, "-")
			}
			if found {
				known = true
				t += sum
			}
		}
	}
	if inLanes && laneEnd > t {
		t = laneEnd
	}
	return t, known
}

func minFloat(a, b float64) float64 {
	if a < b {
		return a
	}
	return b
}
