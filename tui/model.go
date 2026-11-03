package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"charm.land/bubbles/v2/textarea"
	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
)

// How often the panel reads the deploy's state.
const tickEvery = 200 * time.Millisecond

type (
	tickMsg time.Time
	lineMsg string
	exitMsg struct{ code int }
	stopMsg struct{} // SIGINT from outside (kill -INT); ctrl+c arrives as a key
	// goneMsg: the terminal hung up or the UI was told to terminate. Nobody
	// is there to press q, so the screen closes when the deploy has.
	goneMsg struct{}
)

type model struct {
	work, root string
	hist       *History
	pgid       int // the deploy's process group: signals go to all of it

	snap      Snapshot
	lastLines map[string]string
	logAt     map[string]time.Time // when each lane's log line last changed
	laneDone  map[string]int64
	now       time.Time

	// What the panel shows, worked out once per tick (computeDisplay), so a
	// bar or a time left only moves when the tick says so.
	disp    map[string]shown // per track: the foreground stage and each lane
	overall shown

	width, height int

	// The deploy's output: the latest lines for the output pane, all of it
	// in the log file. scroll is how many lines up from the newest the pane
	// shows; 0 follows the output.
	output []string
	log    io.Writer
	scroll int

	// The output box's pages: the deploy's own output, then a page per
	// thread (each Lint check, each lane) with a log of its own. page is the
	// one shown, by key; "" is the deploy's.
	threads map[string]*thread
	page    string

	q        *Question
	answered int
	cursor   int
	picks    []bool
	input    textinput.Model
	area     textarea.Model

	stopping int
	done     bool
	exitCode int
	gone     bool // see goneMsg

	// finishedAt is when the deploy ended; runDir is its folder of logs;
	// notify, when set (main sets it, tests don't), tells the person at the
	// desk that it ended: a notification and the terminal's bell.
	finishedAt time.Time
	runDir     string
	notify     func(headline, message string)
}

// shown is a bar and a time left as the panel draws them.
type shown struct {
	key  string  // the step it belongs to: a new step starts its bar afresh
	frac float64 // -1: no bar to draw
	left float64
	ok   bool // left means something
	at   time.Time
}

// logEvery is how often a lane's "▸" line may change: text rewritten in
// place faster than that can't be read.
const logEvery = time.Second

// keepLines is how much output the pane can scroll back through; the log
// file has the rest.
const keepLines = 5000

// thread is a page in the output box: a Lint check or a lane, and its log.
type thread struct {
	key, title string
	path       string   // its log
	state      string   // r running, f failed, d done
	order      int64    // when it started: the pages go in that order
	lines      []string // the end of its log, as last read
}

// threadLines is how much of a thread's log a page keeps.
const threadLines = 2000

func newModel(work, root string, hist *History, pgid int) *model {
	return &model{
		work: work, root: root, hist: hist, pgid: pgid,
		lastLines: map[string]string{},
		logAt:     map[string]time.Time{},
		laneDone:  map[string]int64{},
		disp:      map[string]shown{},
		threads:   map[string]*thread{},
		overall:   shown{frac: -1},
		now:       time.Now(),
	}
}

func tick() tea.Cmd {
	return tea.Tick(tickEvery, func(t time.Time) tea.Msg { return tickMsg(t) })
}

func (m *model) Init() tea.Cmd { return tick() }

// refresh reads the deploy's state, each lane's latest log line, and its
// question.
func (m *model) refresh() tea.Cmd {
	m.snap = ReadSnapshot(m.work)
	for _, l := range m.snap.Lanes {
		if l.OK {
			if _, seen := m.laneDone[l.Name]; !seen {
				m.laneDone[l.Name] = m.now.Unix()
			}
		}
		if l.Log != "" && m.now.Sub(m.logAt[l.Name]) >= logEvery {
			if line := lastLogLine(l.Log); line != "" && line != m.lastLines[l.Name] {
				m.lastLines[l.Name] = line
				m.logAt[l.Name] = m.now
			}
		}
	}
	m.computeDisplay()
	m.updateThreads()
	if m.done {
		m.q = nil
		return nil
	}
	if q, ok := ReadQuestion(m.work); ok && q.ID > m.answered && !Answered(m.work, q) {
		if m.q == nil || m.q.ID != q.ID {
			return m.ask(q)
		}
	} else if m.q != nil && (!ok || q.ID != m.q.ID) {
		m.q = nil
	}
	return nil
}

// updateThreads takes the threads the deploy registered (lib/tracker.sh:
// the API build, the plan and the apply, the web upload, each Lint check)
// and the lanes, and reads the end of the log on the page shown and of one
// that just ended (so a failed check's log is kept after the deploy removes
// $WORK). It also keeps the latest line of the newest running thread for
// the stage's block.
func (m *model) updateThreads() {
	s := m.snap
	seen := func(key, title, path, state string, order int64) {
		t := m.threads[key]
		if t == nil {
			t = &thread{key: key, title: title}
			m.threads[key] = t
		}
		ended := t.state == "r" && state != "r"
		t.path, t.state, t.order = path, state, order
		if path != "" && (ended || key == m.page) {
			if lines := tailLines(path, threadLines); lines != nil {
				t.lines = lines
			}
		}
	}
	for _, l := range s.Lanes {
		if l.Pending || l.Log == "" {
			continue
		}
		state := map[string]string{"b": "r", "d": "d", "f": "f"}[laneState(l)]
		seen("lane:"+l.Name, l.Name, l.Log, state, l.Started)
	}
	newest := ""
	for _, t := range s.Threads {
		state := t.State
		if state == "s" || state == "" {
			state = "d"
		}
		seen("t:"+t.Key, t.Title, t.Log, state, t.Started)
		if state == "r" {
			newest = t.Log
		}
	}
	if newest != "" && m.now.Sub(m.logAt[""]) >= logEvery {
		if line := lastLogLine(newest); line != "" && line != m.lastLines[""] {
			m.lastLines[""] = line
			m.logAt[""] = m.now
		}
	} else if newest == "" {
		m.lastLines[""] = ""
	}
}

// pages is the output box's pages: the deploy's own output, then every
// thread running or failed, and the page shown even once it has finished.
func (m *model) pages() []*thread {
	var out []*thread
	for _, t := range m.threads {
		if t.state == "r" || t.state == "f" || t.key == m.page {
			out = append(out, t)
		}
	}
	// By when they started; threads started in the same second by key, so
	// the tabs never swap places between frames.
	sort.Slice(out, func(i, j int) bool {
		if out[i].order != out[j].order {
			return out[i].order < out[j].order
		}
		return out[i].key < out[j].key
	})
	return append([]*thread{{key: "", title: "Summary", state: "r"}}, out...)
}

// turnPage moves to the next (+1) or previous (-1) page.
func (m *model) turnPage(step int) {
	pages := m.pages()
	at := 0
	for i, p := range pages {
		if p.key == m.page {
			at = i
		}
	}
	at = (at + step + len(pages)) % len(pages)
	if pages[at].key != m.page {
		m.page = pages[at].key
		m.scroll = 0
		if t := m.threads[m.page]; t != nil && t.path != "" {
			if lines := tailLines(t.path, threadLines); lines != nil {
				t.lines = lines
			}
		}
	}
}

// pageLines is the lines of the page shown.
func (m *model) pageLines() []string {
	if t := m.threads[m.page]; m.page != "" && t != nil {
		return t.lines
	}
	return m.output
}

// settle is the value to show for a track: within one step a bar only
// moves forward, and the time left follows a countdown from what was shown,
// pulled toward the new estimate, so it doesn't jitter between minutes.
func (m *model) settle(prev shown, key string, frac, left float64, ok bool) shown {
	next := shown{key: key, frac: frac, left: left, ok: ok, at: m.now}
	if prev.key != key || prev.at.IsZero() {
		return next
	}
	if prev.frac > next.frac {
		next.frac = prev.frac
	}
	if ok && prev.ok {
		countdown := prev.left - m.now.Sub(prev.at).Seconds()
		if countdown < 0 {
			countdown = 0
		}
		next.left = 0.7*countdown + 0.3*left
	}
	return next
}

// computeDisplay works out every bar and time left for this tick.
func (m *model) computeDisplay() {
	s := m.snap
	now := m.now.Unix()
	if s.CurStage >= 0 && s.CurStage < len(s.Stages) {
		stage := s.Stages[s.CurStage]
		left, frac, ok := m.hist.StepRemaining(s.Mode, stage, s.Fg, now)
		m.disp[""] = m.settle(m.disp[""], stage+"/"+s.Fg.Step(), frac, left, ok)
	}
	for _, l := range s.Lanes {
		left, frac, ok := m.hist.StepRemaining(s.Mode, l.Name, l.Progress, now)
		m.disp[l.Name] = m.settle(m.disp[l.Name], l.Step(), frac, left, ok)
	}
	if left, ok := m.hist.Overall(s, now); ok && !m.done {
		el := float64(now - s.Started)
		// One key for the whole run: the overall bar never goes back.
		m.overall = m.settle(m.overall, "run", el/(el+left), left, true)
	}
}

// ask shows a question.
func (m *model) ask(q Question) tea.Cmd {
	m.q = &q
	m.cursor = 0
	m.picks = make([]bool, len(q.Options))
	switch q.Kind {
	case "pick":
		if d, err := strconv.Atoi(q.Default); err == nil && d >= 0 && d < len(q.Options) {
			m.cursor = d
		}
		for m.cursor < len(q.Options) && IsSeparator(q.Options[m.cursor]) {
			m.cursor++
		}
	case "many":
		// The default, when there is one, is a 1 or 0 per option (prompt.sh's
		// PICK_DEFAULTS); else everything starts ticked.
		ticks := strings.Fields(q.Default)
		for i := range m.picks {
			m.picks[i] = len(ticks) != len(m.picks) || ticks[i] != "0"
		}
		q.syncGroups(m.picks)
	case "confirm":
		// No side chosen: Enter alone does nothing, as at the old [y/n].
		m.cursor = -1
	case "text":
		m.input = textinput.New()
		m.input.Prompt = "› "
		m.input.SetValue(q.Default)
		m.input.SetWidth(max(min(m.leftInner()-4, 60), 10))
		return m.input.Focus()
	case "lines":
		m.area = textarea.New()
		m.area.ShowLineNumbers = false
		m.area.SetWidth(max(m.leftInner()-2, 20))
		m.area.SetHeight(6)
		return m.area.Focus()
	}
	return nil
}

// answer hands the answer to the deploy and puts the panel back.
func (m *model) answer(a string) {
	if m.q == nil {
		return
	}
	_ = WriteAnswer(m.work, *m.q, a)
	m.answered = m.q.ID
	m.q = nil
}

// addOutput takes a line of the deploy's output: into the pane's buffer, and
// the log file. A pane scrolled back stays on the lines it shows.
func (m *model) addOutput(line string) {
	m.output = append(m.output, line)
	if len(m.output) > keepLines {
		m.output = m.output[len(m.output)-keepLines:]
	}
	if m.scroll > 0 && m.page == "" {
		m.scroll = min(m.scroll+1, len(m.output)-1)
	}
	if m.log != nil {
		_, _ = io.WriteString(m.log, ansi.Strip(line)+"\n")
	}
}

// scrollBy moves the output pane: up is positive.
func (m *model) scrollBy(n int) {
	m.scroll = max(0, min(m.scroll+n, len(m.pageLines())-1))
}

// stop: the first press asks the deploy to stop (SIGINT, as a terminal's
// ctrl+c would), the second presses it (SIGTERM). Never SIGKILL: the
// deploy's cleanup releases the Terraform state lock, takes back a bump and
// stops the lanes, and a kill mid-apply would skip all of it.
func (m *model) stop() {
	m.stopping++
	var sig syscall.Signal
	switch m.stopping {
	case 1:
		sig = syscall.SIGINT
	case 2:
		sig = syscall.SIGTERM
	default:
		return
	}
	if m.pgid > 0 {
		_ = syscall.Kill(-m.pgid, sig)
	}
}

func (m *model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tickMsg:
		m.now = time.Time(msg)
		cmd := m.refresh()
		if m.done {
			// The clock stops with the deploy; the screen stays until q.
			return m, cmd
		}
		return m, tea.Batch(cmd, tick())
	case lineMsg:
		m.addOutput(string(msg))
		return m, nil
	case exitMsg:
		m.done = true
		m.exitCode = msg.code
		m.now = time.Now()
		m.finishedAt = m.now
		m.refresh()
		if m.gone {
			return m, tea.Quit
		}
		if m.notify != nil {
			_, headline, _ := m.outcome()
			notify, message := m.notify, ansi.Strip(m.finalLine())
			return m, func() tea.Msg { notify(headline, message); return nil }
		}
		return m, nil
	case goneMsg:
		m.gone = true
		if m.done {
			return m, tea.Quit
		}
		return m, nil
	case stopMsg:
		m.stop()
		return m, nil
	case tea.WindowSizeMsg:
		m.width, m.height = msg.Width, msg.Height
		return m, nil
	case tea.KeyPressMsg:
		return m.key(msg)
	}
	if m.q != nil {
		return m.passToInput(msg)
	}
	return m, nil
}

func (m *model) passToInput(msg tea.Msg) (tea.Model, tea.Cmd) {
	var cmd tea.Cmd
	switch m.q.Kind {
	case "text":
		m.input, cmd = m.input.Update(msg)
	case "lines":
		m.area, cmd = m.area.Update(msg)
	}
	return m, cmd
}

func (m *model) move(step int) {
	q := m.q
	i := m.cursor + step
	for i >= 0 && i < len(q.Options) && IsSeparator(q.Options[i]) {
		i += step
	}
	if i >= 0 && i < len(q.Options) {
		m.cursor = i
	}
}

// outputPage is how far PgUp and PgDn move the output pane.
func (m *model) outputPage() int { return max(m.height/2, 5) }

func (m *model) key(k tea.KeyPressMsg) (tea.Model, tea.Cmd) {
	// The output's pages: ←/→ unless a question has the keys, tab always
	// (but in the note's text box, where it's typing).
	typing := m.q != nil && !m.done && (m.q.Kind == "text" || m.q.Kind == "lines")
	switch k.String() {
	case "left", "right":
		if m.q == nil || m.done {
			m.turnPage(map[string]int{"left": -1, "right": 1}[k.String()])
			return m, nil
		}
	case "tab", "shift+tab":
		if !typing && (m.q == nil || m.q.Kind != "confirm" || m.done) {
			m.turnPage(map[string]int{"tab": 1, "shift+tab": -1}[k.String()])
			return m, nil
		}
	}
	switch k.String() {
	case "pgup":
		m.scrollBy(m.outputPage())
		return m, nil
	case "pgdown":
		m.scrollBy(-m.outputPage())
		return m, nil
	case "end":
		if m.q == nil || (m.q.Kind != "text" && m.q.Kind != "lines") {
			m.scroll = 0
			return m, nil
		}
	}
	if m.done {
		// The deploy has ended: the screen stays until it's read.
		switch k.String() {
		case "q", "enter", "esc", "ctrl+c":
			return m, tea.Quit
		case "up", "k":
			m.scrollBy(1)
		case "down", "j":
			m.scrollBy(-1)
		}
		return m, nil
	}
	if k.String() == "ctrl+c" {
		m.stop()
		return m, nil
	}
	if m.q == nil || m.stopping > 0 {
		return m, nil
	}
	q := m.q
	switch q.Kind {
	case "pick", "many":
		switch k.String() {
		case "up", "k":
			m.move(-1)
		case "down", "j":
			m.move(1)
		case "space":
			if q.Kind == "many" {
				q.toggle(m.picks, m.cursor)
			}
		case "enter":
			if q.Kind == "pick" {
				m.answer(strconv.Itoa(m.cursor))
			} else {
				var bits []string
				for _, p := range m.picks {
					bits = append(bits, map[bool]string{true: "1", false: "0"}[p])
				}
				m.answer(strings.Join(bits, " "))
			}
		}
		return m, nil
	case "confirm":
		switch k.String() {
		case "y", "Y":
			m.answer("y")
		case "n", "N":
			m.answer("n")
		case "left", "h", "up", "k":
			m.cursor = 0
		case "right", "l", "down", "j", "tab":
			m.cursor = 1
		case "enter":
			if m.cursor == 0 {
				m.answer("y")
			} else if m.cursor == 1 {
				m.answer("n")
			}
		}
		return m, nil
	case "text":
		if k.String() == "enter" {
			v := strings.TrimSpace(m.input.Value())
			if v == "" {
				v = q.Default
			}
			m.answer(v)
			return m, nil
		}
	case "lines":
		if k.String() == "ctrl+d" {
			m.answer(strings.TrimRight(m.area.Value(), "\n"))
			return m, nil
		}
	}
	return m.passToInput(k)
}

func (m *model) View() tea.View {
	v := tea.NewView(m.render())
	v.AltScreen = true
	// The terminal's tab says how far, then how it ended.
	switch {
	case m.done:
		kind, headline, _ := m.outcome()
		v.WindowTitle = map[string]string{"ok": "✓", "stopped": "■", "failed": "✗"}[kind] + " " + appSlug() + " deploy: " + strings.ToLower(headline)
	case m.overall.frac >= 0:
		v.WindowTitle = fmt.Sprintf("%s deploy · %d%%", appSlug(), int(m.overall.frac*100))
	default:
		v.WindowTitle = appSlug() + " deploy"
	}
	switch {
	case m.done && m.exitCode != 0:
		v.ProgressBar = tea.NewProgressBar(tea.ProgressBarError, 100)
	case m.done:
		v.ProgressBar = tea.NewProgressBar(tea.ProgressBarNone, 0)
	case m.snap.Ready:
		now := m.now.Unix()
		if left, ok := m.hist.Overall(m.snap, now); ok {
			el := float64(now - m.snap.Started)
			v.ProgressBar = tea.NewProgressBar(tea.ProgressBarDefault, int(100*el/(el+left)))
		} else {
			v.ProgressBar = tea.NewProgressBar(tea.ProgressBarIndeterminate, 0)
		}
	}
	return v
}

// lastLogLine is the latest line of a lane's log worth showing: the text
// after a carriage return's overwrite, without colour, not blank and not a
// table's border.
func lastLogLine(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	const tail = 8192
	if st, err := f.Stat(); err == nil && st.Size() > tail {
		_, _ = f.Seek(st.Size()-tail, 0)
	}
	buf := make([]byte, tail)
	n, _ := f.Read(buf)
	lines := bytes.Split(buf[:n], []byte("\n"))
	for i := len(lines) - 1; i >= 0; i-- {
		line := cleanLine(string(lines[i]))
		if line == "" || strings.Trim(line, "+-=|─━ ") == "" {
			continue
		}
		return line
	}
	return ""
}

// tailLines is the last n lines of a log, each as a terminal would show it
// (after a carriage return's overwrite), or nil when it can't be read.
func tailLines(path string, n int) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	const most = 256 * 1024
	if st, err := f.Stat(); err == nil && st.Size() > most {
		_, _ = f.Seek(st.Size()-most, 0)
	}
	b, _ := io.ReadAll(f)
	raw := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(raw) > n {
		raw = raw[len(raw)-n:]
	}
	out := make([]string, len(raw))
	for i, l := range raw {
		out[i] = outputLine(l)
	}
	return out
}

// cleanLine is what a terminal would show of a line: after its last
// carriage return, without escape codes or a fastlane timestamp.
func cleanLine(s string) string {
	s = strings.TrimRight(s, "\r")
	if i := strings.LastIndex(s, "\r"); i >= 0 {
		s = s[i+1:]
	}
	s = strings.TrimSpace(ansi.Strip(s))
	if len(s) > 11 && s[0] == '[' && s[9] == ']' && s[10] == ':' {
		s = strings.TrimSpace(s[11:])
	}
	return strings.TrimSpace(strings.TrimPrefix(s, "▸"))
}

// outputLine is a line of the deploy's own output as it should print:
// after the last carriage return's overwrite.
func outputLine(s string) string {
	s = strings.TrimRight(s, "\r")
	if i := strings.LastIndex(s, "\r"); i >= 0 {
		s = s[i+1:]
	}
	return s
}
