package main

import (
	"testing"
)

func FuzzNormalizePTYSize(f *testing.F) {
	f.Add(80, 24)
	f.Add(0, 0)
	f.Add(-1, -100)
	f.Add(1_000_000, 1_000_000)

	f.Fuzz(func(t *testing.T, cols int, rows int) {
		gotCols, gotRows := normalizePTYSize(cols, rows)
		if gotCols <= 0 || gotRows <= 0 {
			t.Fatalf("normalizePTYSize(%d, %d) = %dx%d, expected positive dimensions", cols, rows, gotCols, gotRows)
		}
		if gotCols > maxPTYDimension || gotRows > maxPTYDimension {
			t.Fatalf("normalizePTYSize(%d, %d) = %dx%d, expected <= %d", cols, rows, gotCols, gotRows, maxPTYDimension)
		}
	})
}
