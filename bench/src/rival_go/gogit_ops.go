// go-git's side of the operation workloads (relic's src/ops.zig, git's
// src/git_ops.py): the same repositories, the same identity, the same
// metrics where go-git can produce them. An operation go-git has no API for
// prints `unavailable` with the reason, rather than being rebuilt here from
// plumbing.
package main

import (
	"bytes"
	"context"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	git "github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
)

const hotPath = "d00/d00/f0000.txt"

var opNames = []string{
	"diff-tree", "diff-renames", "diff-patch", "diff-index", "log", "log-path",
	"revparse", "merge-base", "merge-tree-clean", "merge-tree-conflict", "merge-clean", "merge-conflict",
	"rebase", "cherry-pick", "revert", "commit", "switch", "stash",
	"branch-create", "tag-create", "ref-list", "repack", "verify", "worktree-add",
	"lfs-add", "lfs-checkout", "submodule-status", "submodule-update", "snapshot", "patch-id",
}

// What go-git cannot do, and why.
var opUnavailable = map[string]string{
	"patch-id":            "go-git has no patch-id",
	"merge-tree-clean":    "go-git has no three-way merge, only fast-forward",
	"merge-tree-conflict": "go-git has no three-way merge, only fast-forward",
	"merge-clean":         "go-git merges by fast-forward only",
	"merge-conflict":      "go-git merges by fast-forward only",
	"rebase":              "go-git has no rebase",
	"cherry-pick":         "go-git has no cherry-pick",
	"revert":              "go-git has no revert",
	"stash":               "go-git has no stash",
	"verify":              "go-git has no pack or object verification",
	"worktree-add":        "go-git has no linked worktrees",
	"lfs-add":             "go-git has no LFS",
	"lfs-checkout":        "go-git has no LFS",
	"snapshot":            "go-git has no stash create or snapshot",
}

var who = &object.Signature{Name: "Bench", Email: "bench" + "\x40" + "example.invalid", When: time.Unix(1700000000, 0).UTC()}

func smoke() bool { return os.Getenv("BENCH_SMOKE") == "1" }

func reps() int {
	if smoke() {
		return 1
	}
	return 3
}

func isOp(command string) bool {
	for _, n := range opNames {
		if n == command {
			return true
		}
	}
	return false
}

func unavailable(workload, reason string) {
	fmt.Printf("go-git\t%s\ttime\tunavailable\tms\n", workload)
	fmt.Printf("go-git\t%s\treason\t%s\ttext\n", workload, reason)
}

func emitCount(workload, metric string, n int) { emit(workload, metric, float64(n), "count") }

func emitOid(workload, metric string, h plumbing.Hash) {
	fmt.Printf("go-git\t%s\t%s\t%s\toid\n", workload, metric, h.String())
}

func emitText(workload, metric, text string) {
	fmt.Printf("go-git\t%s\t%s\t%s\ttext\n", workload, metric, text)
}

// best runs fn reps() times and returns the shortest time.
func best(fn func()) float64 {
	b := math.MaxFloat64
	for i := 0; i < reps(); i++ {
		start := benchmarkNow()
		fn()
		b = math.Min(b, ms(start))
	}
	return b
}

func resolve(r *git.Repository, rev string) plumbing.Hash {
	h, err := r.ResolveRevision(plumbing.Revision(rev))
	check(err)
	return *h
}

func commitTree(r *git.Repository, rev string) *object.Tree {
	c, err := r.CommitObject(resolve(r, rev))
	check(err)
	t, err := c.Tree()
	check(err)
	return t
}

func headTree(r *git.Repository) plumbing.Hash {
	head, err := r.Head()
	check(err)
	c, err := r.CommitObject(head.Hash())
	check(err)
	return c.TreeHash
}

func runOp(w, repo, extra string) {
	if reason, ok := opUnavailable[w]; ok {
		unavailable(w, reason)
		return
	}
	switch w {
	case "diff-tree", "diff-renames":
		oldRev, newRev, renames := "refs/tags/fork", "refs/heads/main", false
		if w == "diff-renames" {
			oldRev, newRev, renames = "refs/heads/main", "refs/heads/renamed", true
		}
		var counts [5]int
		took := best(func() {
			r, err := git.PlainOpen(repo)
			check(err)
			changes, err := object.DiffTreeWithOptions(context.Background(), commitTree(r, oldRev), commitTree(r, newRev),
				&object.DiffTreeOptions{DetectRenames: renames, RenameScore: 50, RenameLimit: 1000})
			check(err)
			counts = [5]int{}
			for _, ch := range changes {
				counts[0]++
				switch {
				case ch.From.Name == "":
					counts[1]++
				case ch.To.Name == "":
					counts[2]++
				case ch.From.Name != ch.To.Name:
					counts[4]++
				default:
					counts[3]++
				}
			}
		})
		emit(w, "time", took, "ms")
		for i, m := range []string{"changes", "added", "deleted", "modified", "renamed"} {
			emitCount(w, m, counts[i])
		}
	case "diff-patch":
		var text []byte
		took := best(func() {
			r, err := git.PlainOpen(repo)
			check(err)
			changes, err := object.DiffTree(commitTree(r, "refs/tags/fork"), commitTree(r, "refs/heads/main"))
			check(err)
			patch, err := changes.Patch()
			check(err)
			var buf bytes.Buffer
			check(patch.Encode(&buf))
			text = buf.Bytes()
		})
		plus, minus := 0, 0
		for _, l := range bytes.Split(text, []byte("\n")) {
			if bytes.HasPrefix(l, []byte("+++ ")) || bytes.HasPrefix(l, []byte("--- ")) {
				continue
			}
			if bytes.HasPrefix(l, []byte("+")) {
				plus++
			} else if bytes.HasPrefix(l, []byte("-")) {
				minus++
			}
		}
		emit(w, "time", took, "ms")
		emitCount(w, "insertions", plus)
		emitCount(w, "deletions", minus)
		emit(w, "patch_bytes", float64(len(text)), "bytes")
	case "diff-index":
		files := 0
		took := best(func() {
			r, err := git.PlainOpen(repo)
			check(err)
			wt, err := r.Worktree()
			check(err)
			st, err := wt.Status()
			check(err)
			files = 0
			for _, s := range st {
				if s.Worktree == git.Modified {
					files++
				}
			}
		})
		emit(w, "time", took, "ms")
		emitCount(w, "files", files)
		emitText(w, "reason", "line counts: go-git's worktree status names files and has no index-to-worktree patch")
	case "log":
		n := 0
		took := best(func() {
			r, err := git.PlainOpen(repo)
			check(err)
			iter, err := r.Log(&git.LogOptions{From: resolve(r, "refs/heads/main")})
			check(err)
			n = 0
			check(iter.ForEach(func(c *object.Commit) error {
				n++
				_ = len(c.Author.Name) + len(c.Message)
				return nil
			}))
		})
		emit(w, "time", took, "ms")
		emitCount(w, "commits", n)
	case "log-path":
		// Once, not best of three: go-git's file filter diffs every
		// commit's whole tree against its parent's, which takes tens of
		// seconds on the medium and large fixtures.
		n := 0
		start := benchmarkNow()
		r, err := git.PlainOpen(repo)
		check(err)
		path := hotPath
		iter, err := r.Log(&git.LogOptions{From: resolve(r, "refs/heads/main"), FileName: &path})
		check(err)
		check(iter.ForEach(func(c *object.Commit) error { n++; return nil }))
		took := ms(start)
		emit(w, "time", took, "ms")
		emitCount(w, "commits", n)
	case "revparse":
		data, err := os.ReadFile(extra)
		check(err)
		exprs := strings.Fields(string(data))
		n := 0
		took := best(func() {
			r, err := git.PlainOpen(repo)
			check(err)
			n = 0
			for _, e := range exprs {
				resolve(r, e)
				n++
			}
		})
		emit(w, "time", took, "ms")
		emitCount(w, "resolved", n)
	case "merge-base":
		var base plumbing.Hash
		ancestor := false
		took := best(func() {
			r, err := git.PlainOpen(repo)
			check(err)
			main, err := r.CommitObject(resolve(r, "refs/heads/main"))
			check(err)
			side, err := r.CommitObject(resolve(r, "refs/heads/side"))
			check(err)
			bases, err := main.MergeBase(side)
			check(err)
			base = bases[0].Hash
			fork, err := r.CommitObject(resolve(r, "refs/tags/fork"))
			check(err)
			ancestor, err = fork.IsAncestor(main)
			check(err)
		})
		emit(w, "time", took, "ms")
		emitOid(w, "base", base)
		a := 0
		if ancestor {
			a = 1
		}
		emitCount(w, "ancestor", a)
	case "commit":
		start := benchmarkNow()
		r, err := git.PlainOpen(repo)
		check(err)
		wt, err := r.Worktree()
		check(err)
		h, err := wt.Commit("bench commit\n", &git.CommitOptions{Author: who, Committer: who})
		check(err)
		took := ms(start)
		c, err := r.CommitObject(h)
		check(err)
		emit(w, "time", took, "ms")
		emitOid(w, "tree", c.TreeHash)
		emitOid(w, "commit", h)
	case "switch":
		start := benchmarkNow()
		r, err := git.PlainOpen(repo)
		check(err)
		wt, err := r.Worktree()
		check(err)
		check(wt.Checkout(&git.CheckoutOptions{Branch: plumbing.NewBranchReferenceName("oldb")}))
		took := ms(start)
		emit(w, "time", took, "ms")
		emitOid(w, "tree", headTree(r))
	case "branch-create":
		count := 1000
		if smoke() {
			count = 10
		}
		start := benchmarkNow()
		r, err := git.PlainOpen(repo)
		check(err)
		main := resolve(r, "refs/heads/main")
		for i := 0; i < count; i++ {
			name := plumbing.ReferenceName(fmt.Sprintf("refs/heads/bench/b%04d", i))
			check(r.Storer.SetReference(plumbing.NewHashReference(name, main)))
		}
		took := ms(start)
		emit(w, "time", took, "ms")
		emitCount(w, "refs", count)
	case "tag-create":
		count := 100
		if smoke() {
			count = 5
		}
		start := benchmarkNow()
		r, err := git.PlainOpen(repo)
		check(err)
		main := resolve(r, "refs/heads/main")
		var first plumbing.Hash
		for i := 0; i < count; i++ {
			ref, err := r.CreateTag(fmt.Sprintf("bench/t%03d", i), main, &git.CreateTagOptions{Tagger: who, Message: "bench tag\n"})
			check(err)
			if i == 0 {
				first = ref.Hash()
			}
		}
		took := ms(start)
		emit(w, "time", took, "ms")
		emitCount(w, "tags", count)
		emitOid(w, "first", first)
	case "ref-list":
		n := 0
		took := best(func() {
			r, err := git.PlainOpen(repo)
			check(err)
			iter, err := r.References()
			check(err)
			n = 0
			check(iter.ForEach(func(ref *plumbing.Reference) error {
				if !strings.HasPrefix(ref.Name().String(), "refs/") {
					return nil
				}
				if ref.Type() == plumbing.SymbolicReference {
					_, err := r.Reference(ref.Name(), true)
					check(err)
				}
				n++
				return nil
			}))
		})
		emit(w, "time", took, "ms")
		emitCount(w, "refs", n)
	case "repack":
		// Every reachable object into one new pack, the old packs and the
		// loose objects it now holds removed: `git repack -a -d`.
		start := benchmarkNow()
		r, err := git.PlainOpen(repo)
		check(err)
		check(r.RepackObjects(&git.RepackConfig{}))
		took := ms(start)
		r, err = git.PlainOpen(repo)
		check(err)
		objects := 0
		iter, err := r.Storer.IterEncodedObjects(plumbing.AnyObject)
		check(err)
		check(iter.ForEach(func(plumbing.EncodedObject) error { objects++; return nil }))
		var packBytes int64
		packs, _ := filepath.Glob(filepath.Join(repo, "objects", "pack", "*.pack"))
		for _, p := range packs {
			st, err := os.Stat(p)
			check(err)
			packBytes += st.Size()
		}
		emit(w, "time", took, "ms")
		emitCount(w, "objects", objects)
		emit(w, "pack_bytes", float64(packBytes), "bytes")
	case "submodule-status":
		n := 0
		took := best(func() {
			r, err := git.PlainOpen(repo)
			check(err)
			wt, err := r.Worktree()
			check(err)
			subs, err := wt.Submodules()
			check(err)
			st, err := subs.Status()
			check(err)
			n = len(st)
		})
		emit(w, "time", took, "ms")
		emitCount(w, "submodules", n)
	case "submodule-update":
		start := benchmarkNow()
		r, err := git.PlainOpen(repo)
		check(err)
		wt, err := r.Worktree()
		check(err)
		subs, err := wt.Submodules()
		check(err)
		check(subs.Update(&git.SubmoduleUpdateOptions{Init: true}))
		took := ms(start)
		emit(w, "time", took, "ms")
		emitCount(w, "submodules", len(subs))
	default:
		panic("unknown workload " + w)
	}
}

// --------------------------------------------------------------- transport

func transport(command string, args []string) {
	// `check` asks for git's transfer.fsckObjects; go-git has no equivalent.
	if len(args) > 0 && args[len(args)-1] == "check" {
		unavailable(command, "go-git has no object checking on receive (transfer.fsckObjects)")
		return
	}
	switch command {
	case "clone":
		url, dst := args[0], args[1]
		if !strings.HasPrefix(url, "http") {
			unavailable(command, "go-git's ssh client cannot run the ssh stand-in program (GIT_SSH_COMMAND)")
			return
		}
		check(os.RemoveAll(dst))
		start := benchmarkNow()
		_, err := git.PlainClone(dst, true, &git.CloneOptions{URL: url})
		check(err)
		emit(command, "time", ms(start), "ms")
	case "fetch", "push":
		dir := args[0]
		r, err := git.PlainOpen(dir)
		check(err)
		remote, err := r.Remote("origin")
		check(err)
		if !strings.HasPrefix(remote.Config().URLs[0], "http") {
			unavailable(command, "go-git's ssh client cannot run the ssh stand-in program (GIT_SSH_COMMAND)")
			return
		}
		start := benchmarkNow()
		r, err = git.PlainOpen(dir)
		check(err)
		if command == "fetch" {
			err = r.Fetch(&git.FetchOptions{RemoteName: "origin"})
		} else {
			err = r.Push(&git.PushOptions{RemoteName: "origin", RefSpecs: []config.RefSpec{"refs/heads/main:refs/heads/main"}})
		}
		if err != git.NoErrAlreadyUpToDate {
			check(err)
		}
		emit(command, "time", ms(start), "ms")
	}
}
