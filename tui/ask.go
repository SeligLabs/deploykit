package main

// Questions from the deploy (deploykit lib/prompt.sh, under
// DEPLOY_UI=tui). Bash writes $WORK/ask/question, replaced atomically,
// and waits for $WORK/ask/answer-<id>:
//
//	id=7
//	kind=pick | many | confirm | text | lines
//	title=Apply this plan to production?
//	default=0                 pick: the option selected first; text: the value
//	                          many: a 1 or 0 per option, the ticks to start from
//	option=Start              pick and many, in order; "" and "---" are
//	option=Cancel             separators pick can't land on
//	parents=- h 1 1 -         many, grouped (optional): h a group's row, the
//	                          group row's index for its members, - neither
//
// Answers: pick, the chosen index; many, a 1 or 0 per option, space
// separated; confirm, y or n; text, the line; lines, the lines typed (none
// keeps what there was).

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Question is one question from the deploy.
type Question struct {
	ID      int
	Kind    string
	Title   string
	Default string
	Options []string
	// Parents groups a many's options (lib/prompt.sh PICK_PARENT): "h" for
	// a group's row, the group row's index for its members, "-" for neither.
	Parents []string
}

// parent is option i's entry in Parents: "-" when ungrouped.
func (q Question) parent(i int) string {
	if i < len(q.Parents) && q.Parents[i] != "" {
		return q.Parents[i]
	}
	return "-"
}

// isGroup reports whether option i is a group's row.
func (q Question) isGroup(i int) bool { return q.parent(i) == "h" }

// isMember reports whether option i sits under a group's row.
func (q Question) isMember(i int) bool { _, err := strconv.Atoi(q.parent(i)); return err == nil }

// syncGroups ticks each group's row when any of its members is ticked.
func (q Question) syncGroups(picks []bool) {
	for i := range picks {
		if q.isGroup(i) {
			picks[i] = false
		}
	}
	for i := range picks {
		if p, err := strconv.Atoi(q.parent(i)); err == nil && p >= 0 && p < len(picks) && picks[i] {
			picks[p] = true
		}
	}
}

// toggle ticks or unticks option i; on a group's row, all its members: ticked
// unless every one already was.
func (q Question) toggle(picks []bool, i int) {
	if i < 0 || i >= len(picks) {
		return
	}
	if q.isGroup(i) {
		all := true
		for j := range picks {
			if q.parent(j) == strconv.Itoa(i) && !picks[j] {
				all = false
			}
		}
		for j := range picks {
			if q.parent(j) == strconv.Itoa(i) {
				picks[j] = !all
			}
		}
	} else {
		picks[i] = !picks[i]
	}
	q.syncGroups(picks)
}

// box is option i's checkbox: [x], [ ] or, for a partly ticked group, [~];
// members are indented under their group.
func (q Question) box(picks []bool, i int) string {
	if q.isGroup(i) {
		on, off := 0, 0
		for j := range picks {
			if q.parent(j) == strconv.Itoa(i) {
				if picks[j] {
					on++
				} else {
					off++
				}
			}
		}
		switch {
		case on > 0 && off > 0:
			return "[~] "
		case on > 0:
			return "[x] "
		}
		return "[ ] "
	}
	b := "[ ] "
	if i < len(picks) && picks[i] {
		b = "[x] "
	}
	if q.isMember(i) {
		return "    " + b
	}
	return b
}

// IsSeparator: a row a pick shows but can't choose.
func IsSeparator(option string) bool { return option == "" || option == "---" }

// ReadQuestion reads the deploy's question, if there is one.
func ReadQuestion(work string) (Question, bool) {
	b, err := os.ReadFile(filepath.Join(work, "ask", "question"))
	if err != nil {
		return Question{}, false
	}
	var q Question
	for _, line := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		key, value, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch key {
		case "id":
			q.ID, _ = strconv.Atoi(value)
		case "kind":
			q.Kind = value
		case "title":
			q.Title = value
		case "default":
			q.Default = value
		case "option":
			q.Options = append(q.Options, value)
		case "parents":
			q.Parents = strings.Fields(value)
		}
	}
	if q.ID == 0 || q.Kind == "" {
		return Question{}, false
	}
	return q, true
}

// Answered reports whether the answer to q is already written.
func Answered(work string, q Question) bool {
	_, err := os.Stat(answerPath(work, q.ID))
	return err == nil
}

func answerPath(work string, id int) string {
	return filepath.Join(work, "ask", fmt.Sprintf("answer-%d", id))
}

// WriteAnswer hands the answer to the deploy: written beside, then moved,
// so bash never reads half of it.
func WriteAnswer(work string, q Question, answer string) error {
	final := answerPath(work, q.ID)
	tmp := final + ".tmp"
	if err := os.WriteFile(tmp, []byte(answer+"\n"), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, final)
}
