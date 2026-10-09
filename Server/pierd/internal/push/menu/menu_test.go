package menu

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

func screen(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	if len(name) > 5 && name[len(name)-5:] == ".json" {
		var v struct{ Screen string }
		if err := json.Unmarshal(b, &v); err != nil {
			t.Fatal(err)
		}
		return v.Screen
	}
	return string(b)
}

func keys(c []Choice) (k []string) {
	for _, x := range c {
		k = append(k, x.Key)
	}
	return
}

func TestRealClaudePermissionScreen(t *testing.T) {
	s := screen(t, "screen_permission.json")
	m := Choices(s)
	if !reflect.DeepEqual(keys(m), []string{"1", "2", "3", "4"}) {
		t.Fatalf("keys %v", keys(m))
	}
	for _, c := range m {
		if contains(c.Label, "│") {
			t.Fatalf("side panel leaked into %q", c.Label)
		}
	}
	a := Classify(m)
	if a.Allow == nil || a.Allow.Key != "1" || a.Always == nil || a.Always.Key != "2" || a.Deny == nil || a.Deny.Key != "4" {
		t.Fatalf("actions %+v", a)
	}
	if _, ok := PermissionMenu(s); !ok {
		t.Fatal("expected a permission menu")
	}
}

func contains(s, sub string) bool { return len(sub) > 0 && indexOf(s, sub) >= 0 }
func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func TestTallPanelScreen(t *testing.T) {
	s := screen(t, "screen_permission_tall_panel.json")
	if !contains(s, "│") {
		t.Fatal("fixture should have a side panel")
	}
	if !reflect.DeepEqual(keys(Choices(s)), []string{"1", "2", "3", "4"}) {
		t.Fatalf("keys %v", keys(Choices(s)))
	}
	a, ok := PermissionMenu(s)
	if !ok || a.Allow.Key != "1" || a.Always.Key != "2" || a.Deny.Key != "4" {
		t.Fatalf("actions %+v", a)
	}
	if contains(StripPanel(s), "│") {
		t.Fatal("panel not stripped")
	}
	if StripPanel(StripPanel(s)) != StripPanel(s) {
		t.Fatal("StripPanel is not idempotent")
	}
}

func TestClaudeExtraPermissionOptions(t *testing.T) {
	a, ok := PermissionMenu(screen(t, "screen_permission_read_project.json"))
	if !ok || a.Allow.Key != "1" || a.Always.Key != "2" || a.Deny.Key != "4" {
		t.Fatalf("actions %+v ok=%v", a, ok)
	}
	c := func(l ...string) (o []Choice) {
		for i, x := range l {
			o = append(o, Choice{string(rune('1' + i)), x})
		}
		return
	}
	auto := Classify(c("Yes", "Yes, and switch to auto mode · handles these prompts", "No"))
	if auto.Allow.Key != "1" || auto.Always.Key != "2" || auto.Deny.Key != "3" {
		t.Fatalf("auto %+v", auto)
	}
	both := Classify(c("Yes", "Yes, and switch to auto mode", "Yes, and don't ask again for ls commands", "No"))
	if both.Allow.Key != "1" || both.Always.Key != "3" || both.Deny.Key != "4" {
		t.Fatalf("both %+v", both)
	}
}

func TestStripPanelLeavesPlainScreensAlone(t *testing.T) {
	if got := StripPanel("a │ b\nc\n\n"); got != "a │ b\nc" {
		t.Fatalf("%q", got)
	}
}

func TestQuestionScreenIsNotAPermission(t *testing.T) {
	s := screen(t, "screen_question.json")
	m := Choices(s)
	if len(m) < 2 || m[0].Label != "Red" || m[1].Label != "Blue" {
		t.Fatalf("menu %v", m)
	}
	if _, ok := PermissionMenu(s); ok {
		t.Fatal("question read as permission")
	}
}

func TestOptionLabelsDropTheQuestionsOwnRows(t *testing.T) {
	// A question drawn as a numbered list ends with Claude Code's own rows, which are not choices.
	s := "● Which layout?\n\n ❯ 1. Three tiers\n   2. One plan\n   3. A table\n   4. Type something.\n   5. Chat about this\n"
	if got := OptionLabels(s); !reflect.DeepEqual(got, []string{"Three tiers", "One plan", "A table"}) {
		t.Fatalf("%v", got)
	}
	if got := OptionLabels(screen(t, "screen_question.json")); len(got) < 2 || got[0] != "Red" {
		t.Fatalf("%v", got)
	}
	if got := OptionLabels(screen(t, "screen_finished.json")); got != nil {
		t.Fatalf("a finished screen offers nothing, got %v", got)
	}
}

func TestStartupDialogsAreNotMenus(t *testing.T) {
	if len(Choices(screen(t, "screen_claude_trust.json"))) != 0 {
		t.Fatal("claude trust dialog has no numbers")
	}
	cx := Choices(screen(t, "screen_codex_trust.json"))
	if len(cx) != 2 || cx[0].Label != "Trust and continue" {
		t.Fatalf("codex trust %v", cx)
	}
	if _, ok := PermissionMenu(screen(t, "screen_codex_trust.json")); ok {
		t.Fatal("trust dialog read as permission")
	}
}

func TestFinishedScreenHasNoMenu(t *testing.T) {
	if len(Choices(screen(t, "screen_finished.json"))) != 0 {
		t.Fatal("finished screen parsed as menu")
	}
}

func TestBorderless(t *testing.T) {
	s := screen(t, "screen_permission_borderless.txt")
	m := Choices(s)
	if !reflect.DeepEqual(keys(m), []string{"1", "2", "3"}) || m[1].Label != "Yes, and don't ask again for rm commands in /home/me/shop" {
		t.Fatalf("%v", m)
	}
	a := Classify(m)
	if a.Allow.Key != "1" || a.Always.Key != "2" || a.Deny.Key != "3" {
		t.Fatalf("%+v", a)
	}
}

func TestMenuRules(t *testing.T) {
	if len(Choices("  2. a\n  3. b\n")) != 0 || len(Choices("  1. only one\n")) != 0 {
		t.Fatal("needs two options counting up from 1")
	}
	if len(Choices("1. a\n2. b\n3. c\n4. d\n5. e\n")) != 4 {
		t.Fatal("max 4")
	}
	if len(Choices("←  ☐ Colour  ☐ Toppings  ✔ Submit →\n1. a\n2. b\n")) != 0 {
		t.Fatal("question form is not a menu")
	}
	if got := Choices("❯ 1. Yes\n  2) No\n"); len(got) != 2 || got[1].Label != "No" {
		t.Fatalf("%v", got)
	}
}

func TestIsQuestionTool(t *testing.T) {
	for _, q := range []string{"", "AskUserQuestion", "request_user_input", "ExitPlanMode"} {
		if !IsQuestionTool(q) {
			t.Fatal(q)
		}
	}
	if IsQuestionTool("Bash") {
		t.Fatal("Bash is a permission")
	}
}

// An option worded as a refusal is never "Always allow", even when it says
// "don't ask again": the key it maps to is pressed with the person's authority.
func TestARefusalIsNeverAlwaysAllow(t *testing.T) {
	a := Classify(Choices("  1. Yes\n  2. No, and don't ask again this session\n  3. No\n"))
	if a.Always != nil {
		t.Fatalf("always = %+v, want none", *a.Always)
	}
	if a.Allow == nil || a.Allow.Key != "1" || a.Deny == nil || a.Deny.Key != "2" {
		t.Fatalf("%+v", a)
	}
}
