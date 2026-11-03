package main

// The deploy UI's screen: three drawn boxes, filling the terminal.
//
//	╭─ Steps ───────────────────────────╮╭─ Output ───────────────────────────╮
//	│ ● Lint                       1:02 ││ ━━ Lint                            │
//	│   [████████░░░░░░░░] 9/15 checks  ││   ✓ go-types                       │
//	│   ✓ go-types ✓ js-lint ● js-types ││   ✓ js-lint                        │
//	│                                   ││ ...                                │
//	│ ◐ iOS · Archive              3:51 ││                                    │
//	│   [██████░░░░░░░░░░] 412/980 ·... ││                                    │
//	│   ▸ Compiling Foo.swift           ││                                    │
//	╰───────────────────────────────────╯╰────────────────────────────────────╯
//	╭─ app deploy · all ─────────────────────────── 12:41 · about 9 min left ─╮
//	│ [█████████████████████████░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░]  46%   │
//	│ ✓ Preflight  ● Lint  ◐ Native  ○ Infra  ○ Web  ◐ iOS  ○ Release      │
//	╰─ ctrl+c stop · pgup/pgdn scroll output ──────────────────────────────╯
//
// The left box holds the running stage and every lane, each in a block of
// fixed rows; a question takes its place. The right box is the deploy's
// output, following the newest line (PgUp/PgDn scroll back, End follows
// again; every line also goes to a log file). The bottom box is the run.
// The boxes' sizes and every block's rows depend only on the terminal's
// size and the set of lanes, never on what they are doing, so nothing moves
// while you read it.

import (
	"fmt"
	"math"
	"os"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

var (
	sBold   = lipgloss.NewStyle().Bold(true)
	sDim    = lipgloss.NewStyle().Faint(true)
	sGreen  = lipgloss.NewStyle().Foreground(lipgloss.Green)
	sCyan   = lipgloss.NewStyle().Foreground(lipgloss.Cyan)
	sCyanB  = lipgloss.NewStyle().Foreground(lipgloss.Cyan).Bold(true)
	sRed    = lipgloss.NewStyle().Foreground(lipgloss.Red)
	sRedB   = lipgloss.NewStyle().Foreground(lipgloss.Red).Bold(true)
	sYellow = lipgloss.NewStyle().Foreground(lipgloss.Yellow)
	sMagB   = lipgloss.NewStyle().Foreground(lipgloss.Magenta).Bold(true)
	sSel    = lipgloss.NewStyle().Foreground(lipgloss.Cyan).Bold(true)
)

var spinner = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// slotW is the widest a track's bar gets.
const slotW = 20

// mark is a state's sign, coloured.
func mark(state string) string {
	switch state {
	case "d":
		return sGreen.Render("✓")
	case "r":
		return sCyanB.Render("●")
	case "b":
		return sCyan.Render("◐")
	case "f":
		return sRedB.Render("✗")
	case "s":
		return sDim.Render("–")
	default:
		return sDim.Render("○")
	}
}

// glyph is a state's sign with a name, both coloured.
func glyph(state, name string) string {
	switch state {
	case "d":
		return sGreen.Render("✓ " + name)
	case "r":
		return sCyanB.Render("● " + name)
	case "b":
		return sCyan.Render("◐ " + name)
	case "f":
		return sRedB.Render("✗ " + name)
	case "s":
		return sDim.Render("– " + name)
	default:
		return sDim.Render("○ " + name)
	}
}

// clock is a duration as m:ss, or h:mm:ss past an hour.
func clock(secs int64) string {
	if secs < 0 {
		secs = 0
	}
	if secs >= 3600 {
		return fmt.Sprintf("%d:%02d:%02d", secs/3600, secs/60%60, secs%60)
	}
	return fmt.Sprintf("%d:%02d", secs/60, secs%60)
}

// about is a time left in words: "about 40 s left", "about 6 min left".
func about(secs float64) string {
	switch {
	case secs < 1:
		return "almost done"
	case secs < 60:
		return fmt.Sprintf("about %d s left", int(math.Ceil(secs/5)*5))
	default:
		return fmt.Sprintf("about %d min left", int(math.Ceil(secs/60)))
	}
}

// bar is a progress bar exactly width cells wide.
func bar(frac float64, width int) string {
	if width < 3 {
		return strings.Repeat(" ", max(width, 0))
	}
	frac = math.Max(0, math.Min(1, frac))
	inner := width - 2
	filled := int(math.Round(frac * float64(inner)))
	return sDim.Render("[") + sCyan.Render(strings.Repeat("█", filled)) +
		sDim.Render(strings.Repeat("░", inner-filled)) + sDim.Render("]")
}

// framed is text centred in a bar-shaped slot, exactly width cells wide.
func framed(text string, width int, style lipgloss.Style) string {
	inner := width - 2
	text = ansi.Truncate(text, inner, "")
	pad := inner - ansi.StringWidth(text)
	l := pad / 2
	return sDim.Render("[") + style.Render(strings.Repeat("·", l)+text+strings.Repeat("·", pad-l)) + sDim.Render("]")
}

// cell is s cut or padded to exactly width cells.
func cell(s string, width int) string {
	if width <= 0 {
		return ""
	}
	s = ansi.Truncate(s, width, "…")
	return s + strings.Repeat(" ", width-ansi.StringWidth(s))
}

// fit truncates a line to the width.
func fit(s string, width int) string {
	if width <= 0 {
		return s
	}
	return ansi.Truncate(s, width, "…")
}

// spaced puts right at the end of a line of width, after left.
func spaced(left, right string, width int) string {
	gap := width - ansi.StringWidth(left) - ansi.StringWidth(right)
	if gap < 2 {
		return fit(left+"  "+right, width)
	}
	return left + strings.Repeat(" ", gap) + right
}

// wrapItems lays items out across lines no wider than width, each line after
// indent.
func wrapItems(indent string, items []string, width int) []string {
	var lines []string
	cur := indent
	empty := true
	for _, it := range items {
		w := ansi.StringWidth(it)
		if !empty && ansi.StringWidth(cur)+2+w > width {
			lines = append(lines, cur)
			cur, empty = indent, true
		}
		if !empty {
			cur += "  "
		}
		cur += it
		empty = false
	}
	return append(lines, cur)
}

// detailFor is what a running track's count, label and time left say.
func detailFor(p Progress, d shown) string {
	var parts []string
	switch {
	case p.Total > 0 && p.N > p.Total:
		parts = append(parts, fmt.Sprintf("%d %s", p.N, p.Label))
	case p.Total > 0:
		c := fmt.Sprintf("%d/%d %s", p.N, p.Total, p.Label)
		if p.LT > 0 {
			c += fmt.Sprintf(" · %d/%d %s", p.LN, p.LT, p.Label2)
		}
		parts = append(parts, c)
	case p.Label != "":
		parts = append(parts, p.Label)
	}
	if d.ok && p.Step() != "Gate" {
		parts = append(parts, about(d.left))
	}
	return strings.Join(parts, " · ")
}

// stepTime is a running step's time so far.
func (m *model) stepTime(p Progress) string {
	if p.StepStart <= 0 {
		return ""
	}
	return clock(m.now.Unix() - p.StepStart)
}

// laneEnd is when a finished lane stopped its clock.
func (m *model) laneEnd(l Lane) int64 {
	if t, ok := m.laneDone[l.Name]; ok {
		return t
	}
	return m.now.Unix()
}

func (m *model) rel(path string) string {
	if m.root != "" && strings.HasPrefix(path, m.root+"/") {
		return strings.TrimPrefix(path, m.root+"/")
	}
	return path
}

// box draws a bordered box exactly w wide and h tall: a title and a note in
// the top border, a footer in the bottom one, lines inside (cut or padded to
// fit), with dim borders.
func box(title, note, footer string, lines []string, w, h int) []string {
	return boxIn(sDim, title, note, footer, lines, w, h)
}

// boxIn is box with its borders in a style: a finished run's colour.
func boxIn(border lipgloss.Style, title, note, footer string, lines []string, w, h int) []string {
	if w < 8 || h < 2 {
		return nil
	}
	inner := w - 4
	edge := func(left, right, label, label2 string) string {
		out := border.Render(left + "─")
		used := 2 + 1 // the corners and the first dash
		if label != "" {
			label = " " + ansi.Truncate(label, w-8, "…") + " "
			out += label
			used += ansi.StringWidth(label)
		}
		tail := ""
		if label2 != "" {
			tail = " " + label2 + " "
			if used+ansi.StringWidth(tail)+2 > w {
				tail = ""
			}
		}
		fill := w - used - ansi.StringWidth(tail) - 1
		return out + border.Render(strings.Repeat("─", max(fill, 0))) + tail + border.Render("─"+right)
	}
	out := []string{edge("╭", "╮", title, note)}
	for i := 0; i < h-2; i++ {
		line := ""
		if i < len(lines) {
			line = lines[i]
		}
		out = append(out, border.Render("│")+" "+cell(line, inner)+" "+border.Render("│"))
	}
	return append(out, edge("╰", "╯", footer, ""))
}

// beside joins two boxes of the same height side by side.
func beside(a, b []string) []string {
	out := make([]string, max(len(a), len(b)))
	for i := range out {
		if i < len(a) {
			out[i] += a[i]
		}
		if i < len(b) {
			out[i] += b[i]
		}
	}
	return out
}

// twoPanes is the narrowest terminal that gets the output box beside the
// steps; a narrower one gets the steps alone (the log file has the output).
const twoPanes = 84

// dims is the screen's size and the two top boxes' widths.
func (m *model) dims() (width, height, left, right int) {
	width, height = m.width, m.height
	if width <= 0 {
		width = 120
	}
	if height <= 0 {
		height = 40
	}
	left = width
	if width >= twoPanes {
		left = width / 2
		right = width - left
	}
	return
}

// leftInner is the steps box's text width.
func (m *model) leftInner() int {
	_, _, left, _ := m.dims()
	return left - 4
}

// barW is a track's bar width in the steps box, from the box's width alone.
func barW(inner int) int { return max(10, min(slotW, inner-30)) }

// stepRows is how many rows the running stage's step list keeps: the
// longest stage's, so moving from stage to stage never moves the lanes.
func (m *model) stepRows(inner int) int {
	n := 1
	for _, steps := range m.snap.Plan {
		var items []string
		for _, st := range steps {
			items = append(items, "○ "+st)
		}
		n = max(n, len(wrapItems("  ", items, inner)))
	}
	return n
}

// level is how much each block in the steps box shows; a short terminal
// gets less.
type level struct {
	stageSteps bool // the running stage's step list
	laneLog    bool // a lane's latest log line
	blanks     bool // a blank row between blocks
	oneRow     bool // every block on one row
}

// levels, fullest first.
var levels = []level{
	{stageSteps: true, laneLog: true, blanks: true},
	{stageSteps: true, laneLog: true},
	{stageSteps: true},
	{},
	{oneRow: true},
}

// blockRows is a level's rows in the steps box, from the counts alone.
func (m *model) blockRows(lv level, inner int) int {
	lanes := len(m.snap.Lanes)
	if lv.oneRow {
		return 1 + lanes
	}
	n := 2
	if lv.stageSteps {
		n += m.stepRows(inner)
	}
	if lv.laneLog {
		n += 1 + 3*lanes // the stage's latest line too
	} else {
		n += 2 * lanes
	}
	if lv.blanks {
		n += lanes
	}
	return n
}

// trackHead is a block's first row: mark, name, step, and the time on the
// right.
func trackHead(state, name, step, t string, inner int) string {
	left := mark(state) + " " + sBold.Render(name)
	if step != "" {
		left += sDim.Render(" · ") + step
	}
	return spaced(left, sDim.Render(t), inner)
}

// trackBar is a block's second row: the slot, then what it says.
func trackBar(slot, detail string, style lipgloss.Style, inner int) string {
	return "  " + slot + "  " + style.Render(cell(detail, max(inner-4-ansi.StringWidth(slot), 0)))
}

// slot is a running track's bar, or a spinner where there is nothing to
// measure yet.
func (m *model) slot(d shown, w int) string {
	if d.frac >= 0 {
		return bar(d.frac, w)
	}
	return framed(" "+spinner[int(m.now.UnixMilli()/100)%len(spinner)]+" working ", w, sCyan)
}

// stageBlock is the running stage: its row, its bar, and its step list in
// the rows the longest stage needs.
func (m *model) stageBlock(lv level, inner int) []string {
	s := m.snap
	bw := barW(inner)
	stage, state := "", "p"
	if s.CurStage >= 0 && s.CurStage < len(s.Stages) {
		stage, state = s.Stages[s.CurStage], s.StageState(s.CurStage)
	}
	d := m.disp[""]
	if lv.oneRow {
		return []string{m.oneRowTrack(state, stage, s.Fg, d, m.stepTime(s.Fg), inner)}
	}
	_, isLane := s.Lane(stage)
	var head, second string
	switch {
	case stage == "":
		head = trackHead("p", "Starting", "", "", inner)
		second = trackBar(framed("starting", bw, sDim), "", sDim, inner)
	case m.done || s.Final != "":
		head = trackHead(state, stage, "", "", inner)
		second = trackBar(bar(1, bw), "", sDim, inner)
	case isLane:
		// Joining a lane: its own block below has its bar.
		head = trackHead(state, stage, s.Fg.Step(), m.stepTime(s.Fg), inner)
		second = trackBar(framed(" in its lane ", bw, sDim), "its block is below", sDim, inner)
	default:
		head = trackHead(state, stage, s.Fg.Step(), m.stepTime(s.Fg), inner)
		second = trackBar(m.slot(d, bw), detailFor(s.Fg, d), sBold, inner)
	}
	out := []string{head, second}
	if lv.laneLog {
		// The latest line of what the stage is running (its newest thread):
		// a fixed row, blank when there is none.
		under := ""
		if line := m.lastLines[""]; line != "" && !m.done && !isLane {
			under = "  " + sDim.Render(cell("▸ "+line, inner-2))
		}
		out = append(out, under)
	}
	if lv.stageSteps {
		var items []string
		for i, st := range s.Fg.Steps {
			items = append(items, glyph(s.Fg.State(i), st))
		}
		grid := wrapItems("  ", items, inner)
		for len(grid) < m.stepRows(inner) {
			grid = append(grid, "")
		}
		out = append(out, grid...)
	}
	return out
}

// laneState is a lane's state letter.
func laneState(l Lane) string {
	switch {
	case l.Pending:
		return "p"
	case l.OK:
		return "d"
	case !l.Alive:
		return "f"
	default:
		return "b"
	}
}

// laneBlock is a lane: its row, its bar, and the latest line of its log.
func (m *model) laneBlock(l Lane, lv level, inner int) []string {
	if lv.oneRow {
		return []string{m.oneRowTrack(laneState(l), l.Name, l.Progress, m.disp[l.Name], m.stepTime(l.Progress), inner)}
	}
	bw := barW(inner)
	var head, second, log string
	logStyle := sDim
	switch {
	case l.Pending:
		head = trackHead("p", l.Name, "", "", inner)
		second = trackBar(framed(" starting ", bw, sDim), "", sDim, inner)
	case l.OK:
		what := l.Result
		if what == "" {
			what = "done"
		}
		head = trackHead("d", l.Name, "", clock(m.laneEnd(l)-l.Started), inner)
		second = trackBar(sGreen.Render(bar(1, bw)), what, sGreen, inner)
	case !l.Alive:
		head = trackHead("f", l.Name, l.Step(), "", inner)
		second = trackBar(framed(" stopped ", bw, sRed), "log "+m.rel(l.Log), sRed, inner)
		log, logStyle = m.lastLines[l.Name], sRed
	case l.Step() == "Gate":
		head = trackHead("b", l.Name, "Gate", m.stepTime(l.Progress), inner)
		second = trackBar(framed(" waiting ", bw, sDim), l.Label, sDim, inner)
		log = m.lastLines[l.Name]
	default:
		d := m.disp[l.Name]
		head = trackHead("b", l.Name, l.Step(), m.stepTime(l.Progress), inner)
		second = trackBar(m.slot(d, bw), detailFor(l.Progress, d), lipgloss.NewStyle(), inner)
		log = m.lastLines[l.Name]
	}
	out := []string{head, second}
	if lv.laneLog {
		under := ""
		if log != "" && !m.done {
			under = "  " + logStyle.Render(cell("▸ "+log, inner-2))
		}
		out = append(out, under)
	}
	return out
}

// oneRowTrack is a block squeezed onto one row: mark, name, step, a short
// bar, how far (the count, or the percent), and the time when there is room.
// The bar's and the count's widths come from the box's width alone.
func (m *model) oneRowTrack(state, name string, p Progress, d shown, t string, inner int) string {
	step := p.Step()
	left := mark(state) + " " + cell(name, 10) + " " + cell(step, 9) + " "
	avail := inner - ansi.StringWidth(left)
	bw := max(6, min(12, avail-10))
	farW := max(0, min(9, avail-bw-1))
	var b, far string
	switch {
	case state == "d":
		b = bar(1, bw)
	case d.frac >= 0 && step != "Gate":
		b = bar(d.frac, bw)
	default:
		b = cell("", bw)
	}
	switch {
	case state == "d" || step == "Gate":
	case p.Total > 0:
		far = fmt.Sprintf("%d/%d", p.N, p.Total)
	case d.frac >= 0:
		far = fmt.Sprintf("%d%%", int(d.frac*100))
	}
	row := left + b + " " + cell(far, farW)
	if t != "" && inner-ansi.StringWidth(row) >= ansi.StringWidth(t)+2 {
		return spaced(row, sDim.Render(t), inner)
	}
	return row
}

// stepsLines is the steps box's content: the running stage, then every lane,
// at the fullest level that fits the rows.
func (m *model) stepsLines(inner, rows int) []string {
	lv := levels[len(levels)-1]
	for _, l := range levels {
		if m.blockRows(l, inner) <= rows {
			lv = l
			break
		}
	}
	out := m.stageBlock(lv, inner)
	for _, l := range m.snap.Lanes {
		if lv.blanks {
			out = append(out, "")
		}
		out = append(out, m.laneBlock(l, lv, inner)...)
	}
	return out
}

// outputLines is the output box's content: the pages' tabs, then the page's
// newest lines that fit, or, scrolled back, the lines that far up, each
// wrapped to the box.
func (m *model) outputLines(inner, rows int) []string {
	lines := m.pageLines()
	var out []string
	for i := len(lines) - 1 - m.scroll; i >= 0 && len(out) < rows-1; i-- {
		// At spaces; a word longer than the line is split.
		wrapped := strings.Split(ansi.Wrap(lines[i], inner, ""), "\n")
		out = append(wrapped, out...)
	}
	if len(out) > rows-1 {
		out = out[len(out)-(rows-1):]
	}
	return append([]string{m.tabs(inner)}, out...)
}

// tabs is the output box's first row: the pages, the one shown picked out,
// as many around it as fit.
func (m *model) tabs(inner int) string {
	pages := m.pages()
	at := 0
	for i, p := range pages {
		if p.key == m.page {
			at = i
		}
	}
	label := func(i int) string {
		p := pages[i]
		name := p.title
		if p.key != "" {
			name = mark(map[string]string{"r": "b", "f": "f", "d": "d"}[p.state]) + " " + p.title
		}
		if i == at {
			return lipgloss.NewStyle().Reverse(true).Bold(true).Render(" " + ansi.Strip(name) + " ")
		}
		return " " + name + " "
	}
	from, to := at, at
	width := ansi.StringWidth(label(at))
	for grew := true; grew; {
		grew = false
		if from > 0 && width+ansi.StringWidth(label(from-1))+4 <= inner {
			from--
			width += ansi.StringWidth(label(from))
			grew = true
		}
		if to < len(pages)-1 && width+ansi.StringWidth(label(to+1))+4 <= inner {
			to++
			width += ansi.StringWidth(label(to))
			grew = true
		}
	}
	var b strings.Builder
	if from > 0 {
		b.WriteString(sDim.Render("‹ "))
	}
	for i := from; i <= to; i++ {
		b.WriteString(label(i))
	}
	if to < len(pages)-1 {
		b.WriteString(sDim.Render(" ›"))
	}
	return b.String()
}

// runLines is the bottom box's content: the overall bar and every stage.
func (m *model) runLines(inner int) []string {
	s := m.snap
	frac := m.overall.frac
	if m.done && m.exitCode == 0 {
		frac = 1
	}
	pct := " --%"
	if frac >= 0 {
		pct = fmt.Sprintf("%3d%%", int(frac*100))
	}
	lines := []string{bar(math.Max(frac, 0), inner-6) + "  " + sBold.Render(pct)}
	var items []string
	for i, name := range s.Stages {
		items = append(items, glyph(s.StageState(i), name))
	}
	return append(lines, wrapItems("", items, inner)...)
}

// runNote is the bottom box's top right: the run's time and its time left.
func (m *model) runNote() string {
	t := clock(m.now.Unix() - m.snap.Started)
	switch {
	case m.done:
		t = "took " + clock(m.finishedAt.Unix()-m.snap.Started)
	case m.overall.ok:
		t += " · " + about(m.overall.left)
	default:
		t += " · estimating"
	}
	return sDim.Render(t)
}

// runFooter is the bottom box's bottom border: the keys, the stopping
// state, or how the deploy ended.
func (m *model) runFooter() string {
	keys := "←/→ output pages · pgup/pgdn scroll"
	switch {
	case m.done:
		return m.finalLine() + sDim.Render(" · q to close")
	case m.stopping == 1:
		return sYellow.Render("Stopping: the deploy is cleaning up. ctrl+c again to press it.")
	case m.stopping > 1:
		return sRed.Render("Stopping now (SIGTERM): waiting for its cleanup to release the state lock.")
	case m.q != nil:
		return sDim.Render("answer on the left · ctrl+c stop · tab output pages · pgup/pgdn scroll")
	default:
		return sDim.Render("ctrl+c stop the deploy · " + keys)
	}
}

func (m *model) questionLines(width int) []string {
	q := m.q
	var lines []string
	title := q.Title
	if title == "" {
		switch q.Kind {
		case "pick":
			title = "Choose one"
		case "many":
			title = "Tick what to run"
		}
	}
	if title != "" {
		lines = append(lines, sBold.Render(title), "")
	}
	switch q.Kind {
	case "pick", "many":
		for i, opt := range q.Options {
			switch {
			case opt == "---":
				lines = append(lines, sDim.Render("    ──────"))
			case opt == "":
				lines = append(lines, "")
			default:
				box := ""
				if q.Kind == "many" {
					box = q.box(m.picks, i)
				}
				if i == m.cursor {
					lines = append(lines, fit(sSel.Render("› "+box+opt), width))
				} else {
					lines = append(lines, fit("  "+box+opt, width))
				}
			}
		}
		hint := "↑/↓ move · enter choose"
		if q.Kind == "many" {
			hint = "↑/↓ move · space tick (a group: all of it) · enter done"
		}
		lines = append(lines, "", sDim.Render(hint))
	case "confirm":
		yes, no := "  Yes  ", "  No  "
		if m.cursor == 0 {
			yes = sSel.Render("› Yes  ")
		}
		if m.cursor == 1 {
			no = sSel.Render("› No  ")
		}
		lines = append(lines, yes+"  "+no, "", sDim.Render("y or n · or ←/→ and enter"))
	case "text":
		lines = append(lines, m.input.View(), "", sDim.Render("enter to accept"))
	case "lines":
		lines = append(lines, strings.Split(m.area.View(), "\n")...)
		lines = append(lines, "", sDim.Render("ctrl+d to finish · leave it empty to keep the note"))
	}
	return lines
}

func (m *model) finalLine() string {
	s := m.snap
	msg := s.Final
	if msg == "" {
		msg = fmt.Sprintf("The deploy ended (exit %d).", m.exitCode)
	}
	switch {
	case strings.Contains(s.FinalStyle, "31") || (s.Final == "" && m.exitCode != 0):
		return sRedB.Render(msg)
	case strings.Contains(s.FinalStyle, "33"):
		return sYellow.Render(msg)
	default:
		return sGreen.Render(msg)
	}
}

// outcome is how the run ended, its headline and its colour: deployed, or
// stopped (ctrl+c, a hangup, a Cancel, or a deploy that stopped itself on
// purpose), or failed.
func (m *model) outcome() (kind, headline string, color lipgloss.Style) {
	switch {
	case m.exitCode == 0:
		return "ok", "DEPLOYED", lipgloss.NewStyle().Foreground(lipgloss.Green)
	case m.exitCode == 129 || m.exitCode == 130 || m.exitCode == 143 || strings.Contains(m.snap.FinalStyle, "33"):
		return "stopped", "STOPPED", lipgloss.NewStyle().Foreground(lipgloss.Yellow)
	default:
		return "failed", "FAILED", lipgloss.NewStyle().Foreground(lipgloss.Red)
	}
}

// finishedLines is the steps box once the deploy has ended: a band in the
// result's colour across the box, the deploy's last word, every stage's
// result, and where its logs are.
func (m *model) finishedLines(inner int) []string {
	s := m.snap
	kind, headline, color := m.outcome()
	sign := map[string]string{"ok": "✓", "stopped": "■", "failed": "✗"}[kind]
	took := clock(m.finishedAt.Unix() - s.Started)
	band := lipgloss.NewStyle().Bold(true).Reverse(true).Foreground(color.GetForeground()).
		Render(cell(fmt.Sprintf(" %s %s   in %s · finished %s", sign, headline, took, m.finishedAt.Format("15:04")), inner))
	lines := []string{band, ""}
	if s.Final != "" {
		for _, l := range strings.Split(ansi.Wrap(s.Final, inner, ""), "\n") {
			lines = append(lines, color.Render(l))
		}
		lines = append(lines, "")
	}
	lanes := map[string]Lane{}
	for _, l := range s.Lanes {
		lanes[l.Name] = l
	}
	for i, name := range s.Stages {
		state := s.StageState(i)
		var what string
		if l, ok := lanes[name]; ok {
			switch {
			case l.OK && l.Result != "":
				what, state = l.Result, "d"
			case l.OK:
				what, state = "done", "d"
			case l.Pending:
				what, state = "not started", "s"
			default:
				what, state = "stopped at "+l.Step()+" · log "+m.rel(l.Log), "f"
			}
		} else {
			what = map[string]string{"d": "done", "s": "skipped", "f": "failed", "r": "stopped here", "b": "stopped", "p": "not reached"}[state]
		}
		lines = append(lines, glyph(state, cell(name, 11))+" "+what)
	}
	lines = append(lines, "")
	if m.runDir != "" {
		lines = append(lines, sDim.Render("Every log of this run: "+tildePath(m.runDir)+"/"))
	}
	return append(lines, sDim.Render("q to close · ←/→ each thread's log · pgup/pgdn scroll"))
}

// tildePath is a path with the home folder as ~.
func tildePath(p string) string {
	if home, err := os.UserHomeDir(); err == nil && strings.HasPrefix(p, home+"/") {
		return "~/" + strings.TrimPrefix(p, home+"/")
	}
	return p
}

// render is the whole screen.
func (m *model) render() string {
	width, height, left, right := m.dims()
	if !m.snap.Ready {
		msg := sMagB.Render(appSlug()+" deploy") + sDim.Render(" · starting")
		if m.done {
			msg = m.finalLine() + sDim.Render(" · q to close")
		}
		return msg
	}
	title := sMagB.Render(appSlug() + " deploy")
	if m.snap.Mode != "" {
		title += sDim.Render(" · " + m.snap.Mode)
	}
	// A finished run puts its colour on the boxes' borders.
	border := sDim
	if m.done {
		_, _, border = m.outcome()
	}
	run := m.runLines(width - 4)
	bottom := boxIn(border, title, m.runNote(), m.runFooter(), run, width, len(run)+2)
	topH := max(height-len(bottom), 4)

	stepsTitle := "Steps"
	var stepsBody []string
	switch {
	case m.done:
		stepsTitle = "Finished"
		stepsBody = m.finishedLines(left - 4)
	case m.q != nil && m.stopping == 0:
		stepsTitle = "Your answer"
		stepsBody = m.questionLines(left - 4)
	default:
		stepsBody = m.stepsLines(left-4, topH-2)
	}
	top := boxIn(border, sBold.Render(stepsTitle), "", "", stepsBody, left, topH)
	if right > 0 {
		note := ""
		if m.scroll > 0 {
			note = sYellow.Render(fmt.Sprintf("%d lines up · end to follow", m.scroll))
		}
		top = beside(top, box(sBold.Render("Output"), note, "", m.outputLines(right-4, topH-2), right, topH))
	}
	screen := append(top, bottom...)
	for i := range screen {
		screen[i] = fit(screen[i], width)
	}
	return strings.Join(screen, "\n")
}
