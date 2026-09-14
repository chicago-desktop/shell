// A Go module the AntiBug harness test scans as a `go` target: one test of
// each outcome, so the live scan sees a pass, a failure and a skip arrive.
package antibugfixture

import "testing"

func TestPasses(t *testing.T) {}

func TestFails(t *testing.T) {
	t.Log("reading the row")
	t.Errorf("expected 3 rows, got %d", 2)
}

func TestSkipped(t *testing.T) { t.Skip("postgres only") }
