// go-git's side of the benchmark.
//
// Same six workloads, same timed boundary: the clock starts at "open the
// repository" and stops when the work is done.
package main

import (
	"bufio"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/filemode"
	"github.com/go-git/go-git/v5/plumbing/format/index"
	"github.com/go-git/go-git/v5/plumbing/format/packfile"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/storer"
)

func emit(workload, metric string, value float64, unit string) {
	fmt.Printf("go-git\t%s\t%s\t%.3f\t%s\n", workload, metric, value, unit)
}

// A metric go-git does not report, and why: never a bare n/a.
func notReported(workload, metric, reason string) {
	fmt.Printf("go-git\t%s\t%s\tunavailable\tcount\n", workload, metric)
	fmt.Printf("go-git\t%s\treason\t%s\ttext\n", workload, reason)
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}

func ms(start time.Time) float64 {
	return float64(benchmarkSince(start).Nanoseconds()) / 1e6
}

func main() {
	if len(os.Args) < 3 {
		panic("usage: gogit_bench <workload> <repo> [extra]")
	}
	command, repo := os.Args[1], os.Args[2]
	switch {
	case isOp(command):
		extra := ""
		if len(os.Args) > 3 {
			extra = os.Args[3]
		}
		runOp(command, repo, extra)
		return
	case command == "clone" || command == "fetch" || command == "push":
		transport(command, os.Args[2:])
		return
	}
	extra := ""
	if len(os.Args) > 3 {
		extra = os.Args[3]
	}
	switch command {
	case "status":
		status(repo)
	case "addall":
		addAll(repo)
	case "revlist":
		revList(repo)
	case "catblobs":
		catBlobs(repo, extra)
	case "packwrite":
		packWrite(repo, extra)
	case "indexrw":
		indexRW(repo, extra)
	default:
		panic("unknown workload " + command)
	}
}

// Workload 1: status of a clean worktree with a warm index.
func status(path string) {
	best := math.MaxFloat64
	entries := 0
	for i := 0; i < 5; i++ {
		start := benchmarkNow()
		r, err := git.PlainOpen(path)
		check(err)
		w, err := r.Worktree()
		check(err)
		st, err := w.Status()
		check(err)
		took := ms(start)
		if took < best {
			best = took
		}
		entries = len(st)
	}
	emit("status", "time", best, "ms")
	emit("status", "entries", float64(entries), "count")
}

// Workload 2: add -A then write the tree, on a fresh 1 %-dirty copy.
//
// go-git has no write-tree of its own: the tree is built inside Commit, so
// this measures Add plus Commit and therefore writes one commit object more
// than the other sides do.
func addAll(path string) {
	start := benchmarkNow()
	r, err := git.PlainOpen(path)
	check(err)
	w, err := r.Worktree()
	check(err)
	check(w.AddWithOptions(&git.AddOptions{All: true}))
	_, err = w.Commit("bench", &git.CommitOptions{
		Author: &object.Signature{Name: "Bench", Email: "bench" + "\x40" + "example.invalid", When: time.Unix(1700000000, 0)},
	})
	check(err)
	emit("addall", "time", ms(start), "ms")
}

// Workload 3: every commit, and every tree and blob they reach.
func revList(path string) {
	best := math.MaxFloat64
	objects := 0
	for i := 0; i < 3; i++ {
		start := benchmarkNow()
		r, err := git.PlainOpen(path)
		check(err)
		head, err := r.Head()
		check(err)
		commit, err := r.CommitObject(head.Hash())
		check(err)
		seen := make(map[plumbing.Hash]bool, 1<<16)
		count := 0
		var pending []plumbing.Hash
		iter := object.NewCommitPreorderIter(commit, nil, nil)
		check(iter.ForEach(func(c *object.Commit) error {
			count++ // the commit itself, as `rev-list --objects` prints it
			if !seen[c.TreeHash] {
				seen[c.TreeHash] = true
				pending = append(pending, c.TreeHash)
			}
			return nil
		}))
		for len(pending) > 0 {
			h := pending[len(pending)-1]
			pending = pending[:len(pending)-1]
			count++
			t, err := r.TreeObject(h)
			check(err)
			for _, e := range t.Entries {
				if e.Mode == filemode.Dir {
					if !seen[e.Hash] {
						seen[e.Hash] = true
						pending = append(pending, e.Hash)
					}
				} else if e.Mode != filemode.Submodule {
					if !seen[e.Hash] {
						seen[e.Hash] = true
						count++
					}
				}
			}
		}
		took := ms(start)
		if took < best {
			best = took
		}
		objects = count
	}
	emit("revlist", "time", best, "ms")
	emit("revlist", "objects", float64(objects), "count")
}

// Workload 4: read every blob through the pack.
func catBlobs(path, list string) {
	f, err := os.Open(list)
	check(err)
	var oids []plumbing.Hash
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		oids = append(oids, plumbing.NewHash(line))
	}
	f.Close()

	start := benchmarkNow()
	r, err := git.PlainOpen(path)
	check(err)
	var total int64
	buf := make([]byte, 64*1024)
	for _, h := range oids {
		obj, err := r.Storer.EncodedObject(plumbing.BlobObject, h)
		check(err)
		rd, err := obj.Reader()
		check(err)
		n, err := io.CopyBuffer(io.Discard, rd, buf)
		check(err)
		rd.Close()
		total += n
	}
	took := ms(start)
	mb := float64(total) / 1e6
	emit("catblobs", "throughput", mb/(took/1000.0), "MB/s")
	emit("catblobs", "time", took, "ms")
	emit("catblobs", "bytes", float64(total), "bytes")
}

// countingWriter is how the pack's size is measured without reading it back.
type countingWriter struct {
	w io.Writer
	n int64
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

// Workload 5: pack every loose object, with deltas.
func packWrite(path, scratch string) {
	start := benchmarkNow()
	r, err := git.PlainOpen(path)
	check(err)
	var hashes []plumbing.Hash
	iter, err := r.Storer.IterEncodedObjects(plumbing.AnyObject)
	check(err)
	check(iter.ForEach(func(o plumbing.EncodedObject) error {
		hashes = append(hashes, o.Hash())
		return nil
	}))
	out, err := os.Create(filepath.Join(scratch, "gogit.pack"))
	check(err)
	counter := &countingWriter{w: bufio.NewWriterSize(out, 1<<20)}
	enc := packfile.NewEncoder(counter, r.Storer.(storer.EncodedObjectStorer), false)
	_, err = enc.Encode(hashes, 10)
	check(err)
	counter.w.(*bufio.Writer).Flush()
	out.Close()
	took := ms(start)
	emit("packwrite", "time", took, "ms")
	emit("packwrite", "pack_bytes", float64(counter.n), "bytes")
	emit("packwrite", "objects", float64(len(hashes)), "count")
	notReported("packwrite", "deltas", "go-git's packfile encoder does not report its delta count")
}

// Workload 6: read the index and write it back out.
func indexRW(path, scratch string) {
	src := filepath.Join(path, ".git", "index")
	dst := filepath.Join(scratch, "index.gogit")
	best := math.MaxFloat64
	entries := 0
	for i := 0; i < 10; i++ {
		start := benchmarkNow()
		f, err := os.Open(src)
		check(err)
		var idx index.Index
		check(index.NewDecoder(f).Decode(&idx))
		f.Close()
		w, err := os.Create(dst)
		check(err)
		bw := bufio.NewWriterSize(w, 1<<20)
		check(index.NewEncoder(bw).Encode(&idx))
		bw.Flush()
		w.Close()
		took := ms(start)
		if took < best {
			best = took
		}
		entries = len(idx.Entries)
	}
	emit("indexrw", "time", best, "ms")
	emit("indexrw", "entries", float64(entries), "count")
}

func benchmarkNow() time.Time {
	if os.Getenv("BENCH_SMOKE") == "1" {
		return time.Time{}
	}
	return time.Now()
}
func benchmarkSince(start time.Time) time.Duration {
	if os.Getenv("BENCH_SMOKE") == "1" {
		return time.Nanosecond
	}
	return time.Since(start)
}
