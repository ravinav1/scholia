#!/usr/bin/env python3
"""Isolated-process SQLite FTS5 / Tantivy exact-substring benchmark.

Use the corpus exported by benchmark-workspace-search.mjs. This is an engine
prototype, not a claim that Python bindings predict Swift or Rust performance.
No network service, embedding, credentials, or personal documents are used.
"""
import argparse
import importlib.metadata
import json
import math
from pathlib import Path
import platform
import resource
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import time


CASES = [
    ("rare literal", ["needlemarker"], ""),
    ("absent literal", ["unfindablequartz"], ""),
    ("phrase", ["change of basis"], ""),
    ("multiple terms", ["spectral", "diagonalization"], ""),
    ("workspace scope", ["needlemarker"], "course0"),
    ("common term", ["common"], ""),
    ("short term", ["ab"], ""),
]


def milliseconds(start):
    return (time.perf_counter() - start) * 1000


def peak_mib():
    scale = 1024 ** 2 if sys.platform == "darwin" else 1024
    return round(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / scale, 2)


def summary(values):
    return {"p50Ms": round(statistics.median(values), 3),
            "p95Ms": round(sorted(values)[math.ceil(len(values) * .95) - 1], 3)}


def combine(rows):
    files = {}
    for file, page in rows:
        first, count = files.get(file, (page, 0))
        files[file] = (min(first, page), count + 1)
    found = sorted(((file, page, count) for file, (page, count) in files.items()),
                   key=lambda hit: (hit[1] != 0, hit[0]))
    return len(found), found[:200]


def oracle(corpus, terms, scope):
    return combine((entry["file"]["id"], row["number"])
                   for entry in corpus if not scope or entry["file"]["courseID"] == scope
                   for row in entry["rows"] if all(term in row["text"] for term in terms))


class Planner:
    def reset(self):
        self.frequencies = {}
        self.counts = {}

    def anchors(self, terms, scope):
        grams = list(dict.fromkeys(term[i:i + 3] for term in terms for i in range(len(term) - 2)))
        sampled = []
        n = min(24, len(grams))
        for i in range(n):
            gram = grams[i * len(grams) // n]
            if gram not in self.frequencies:
                self.frequencies[gram] = self.frequency(gram)
            sampled.append((self.frequencies[gram], gram))
            if not sampled[-1][0]:
                return None  # An absent fragment proves no full term can match.
        if scope not in self.counts:
            self.counts[scope] = self.row_count(scope)
        sampled.sort(key=lambda pair: pair[0])
        return [gram for _, gram in sampled[:3]] if sampled and sampled[0][0] < self.counts[scope] / 2 else []


class SQLiteEngine(Planner):
    def __init__(self, path, create=False, **_):
        self.db = sqlite3.connect(str(path / "needle.sqlite"), cached_statements=128)
        self.db.executescript("""
          PRAGMA foreign_keys=ON; PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
          PRAGMA cache_size=-4096; PRAGMA mmap_size=268435456;
        """)
        if create:
            self.db.executescript("""
              CREATE TABLE files(id TEXT PRIMARY KEY, course TEXT NOT NULL, data TEXT NOT NULL);
              CREATE INDEX files_course ON files(course);
              CREATE TABLE passages(id INTEGER PRIMARY KEY, file TEXT NOT NULL REFERENCES files(id) ON DELETE CASCADE,
                page INTEGER NOT NULL, text TEXT NOT NULL);
              CREATE INDEX passages_file ON passages(file,page);
              CREATE VIRTUAL TABLE fragments USING fts5(text,content='passages',content_rowid='id',
                tokenize='trigram case_sensitive 1',detail=none);
              CREATE VIRTUAL TABLE fragment_counts USING fts5vocab(fragments,'row');
              CREATE TRIGGER passages_add AFTER INSERT ON passages BEGIN
                INSERT INTO fragments(rowid,text) VALUES(new.id,new.text); END;
              CREATE TRIGGER passages_remove AFTER DELETE ON passages BEGIN
                INSERT INTO fragments(fragments,rowid,text) VALUES('delete',old.id,old.text); END;
            """)
        self.reset()

    def build(self, corpus):
        for i, entry in enumerate(corpus):
            self.put(entry)
            if (i + 1) % 64 == 0:
                self.db.commit()
        self.db.commit()
        self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    def put(self, entry):
        file = entry["file"]
        self.db.execute("DELETE FROM files WHERE id=?", (file["id"],))
        self.db.execute("INSERT INTO files VALUES(?,?,?)", (file["id"], file["courseID"], json.dumps(file)))
        self.db.executemany("INSERT INTO passages(file,page,text) VALUES(?,?,?)",
                            ((file["id"], row["number"], row["text"]) for row in entry["rows"]))

    def frequency(self, gram):
        row = self.db.execute("SELECT doc FROM fragment_counts WHERE term=?", (gram,)).fetchone()
        return row[0] if row else 0

    def row_count(self, scope):
        sql = "SELECT count(*) FROM passages p JOIN files f ON f.id=p.file"
        return self.db.execute(sql + (" WHERE f.course=?" if scope else ""), (scope,) if scope else ()).fetchone()[0]

    def search(self, terms, scope=""):
        anchors = self.anchors(terms, scope)
        if anchors is None:
            return 0, []
        conditions, params = [], []
        if anchors:
            conditions.append("p.id IN (SELECT rowid FROM fragments WHERE fragments MATCH ?)")
            params.append(" AND ".join('"' + gram.replace('"', '""') + '"' for gram in anchors))
        if scope:
            conditions.append("f.course=?")
            params.append(scope)
        for term in sorted(terms, key=len, reverse=True):
            conditions.append("instr(p.text,?)>0")
            params.append(term)
        hits = self.db.execute("SELECT p.file,min(p.page),count(*) FROM passages p JOIN files f ON f.id=p.file WHERE "
                               + " AND ".join(conditions) + " GROUP BY p.file ORDER BY (min(p.page)=0) DESC,p.file", params).fetchall()
        return len(hits), hits[:200]

    def start_updates(self):
        return 0

    def replace(self, entry, token):
        start = time.perf_counter()
        self.put(entry)
        self.db.commit()
        self.reset()
        commit_ms = milliseconds(start)
        assert self.search([token])[0] == 1
        return {"commitMs": round(commit_ms, 3), "visibleMs": round(milliseconds(start), 3)}

    def close(self):
        self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        self.db.close()


class TantivyEngine(Planner):
    def __init__(self, path, create=False, threads=2):
        import tantivy
        self.t = tantivy
        self.threads = threads
        if create:
            builder = tantivy.SchemaBuilder()
            builder.add_text_field("file", stored=True, tokenizer_name="raw", index_option="basic")
            builder.add_text_field("course", tokenizer_name="raw", index_option="basic")
            builder.add_unsigned_field("page", stored=True)
            builder.add_text_field("text", stored=True, tokenizer_name="trigrams", index_option="basic")
            self.index = tantivy.Index(builder.build(), path=str(path))
        else:
            self.index = tantivy.Index.open(str(path))
        self.schema = self.index.schema
        tokenizer = tantivy.TextAnalyzerBuilder(tantivy.Tokenizer.ngram(3, 3, False)).build()
        self.index.register_tokenizer("trigrams", tokenizer)
        self.index.config_reader(reload_policy="Manual")
        self.searcher = self.index.searcher()
        self.reset()

    def writer(self):
        return self.index.writer(heap_size=64_000_000, num_threads=self.threads)

    def put(self, writer, entry):
        file = entry["file"]
        for row in entry["rows"]:
            writer.add_document(self.t.Document.from_dict({"file": file["id"], "course": file["courseID"],
                                                          "page": row["number"], "text": row["text"]}, self.schema))

    def build(self, corpus):
        writer = self.writer()
        for entry in corpus:
            self.put(writer, entry)
        writer.commit()
        writer.wait_merging_threads()
        self.reload()

    def reload(self):
        self.index.reload()
        self.searcher = self.index.searcher()
        self.reset()

    def frequency(self, gram):
        return self.searcher.doc_freq("text", gram)

    def term(self, field, text):
        return self.t.Query.term_query(self.schema, field, text, index_option="basic")

    def row_count(self, scope):
        return self.searcher.search(self.term("course", scope), limit=1).count if scope else self.searcher.num_docs

    def search(self, terms, scope=""):
        anchors = self.anchors(terms, scope)
        if anchors is None:
            return 0, []
        queries = [self.term("text", gram) for gram in anchors]
        if scope:
            queries.append(self.term("course", scope))
        query = self.t.Query.boolean_query([(self.t.Occur.Must, query) for query in queries]) if queries else self.t.Query.all_query()
        query = self.t.Query.const_score_query(query, 1.0)
        candidates = self.searcher.search(query, limit=max(1, self.searcher.num_docs), count=False)
        hits = []
        for _, address in candidates.hits:
            row = self.searcher.doc(address).to_dict()
            if all(term in row["text"][0] for term in terms):
                hits.append((row["file"][0], row["page"][0]))
        return combine(hits)

    def start_updates(self):
        start = time.perf_counter()
        self.update_writer = self.writer()
        return round(milliseconds(start), 3)

    def replace(self, entry, token):
        start = time.perf_counter()
        writer = self.update_writer
        writer.delete_documents_by_term("file", entry["file"]["id"])
        self.put(writer, entry)
        writer.commit()
        commit_ms = milliseconds(start)
        # The old reader snapshot must remain old until explicit reload.
        assert self.search([token])[0] == 0
        self.reload()
        assert self.search([token])[0] == 1
        visible_ms = milliseconds(start)
        return {"commitMs": round(commit_ms, 3), "visibleMs": round(visible_ms, 3), "requiresReaderReload": True}

    def close(self):
        if hasattr(self, "update_writer"):
            self.update_writer.wait_merging_threads()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--corpus", type=Path)
    parser.add_argument("--rounds", type=int, default=31)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--engine", choices=["sqlite", "tantivy"])
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--path", type=Path)
    parser.add_argument("--reopen", action="store_true")
    args = parser.parse_args()
    if not args.engine:
        if not args.corpus:
            parser.error("--corpus is required; export it with SEARCH_BENCH_CORPUS")
        engines = []
        with tempfile.TemporaryDirectory(prefix="needle-engines-") as directory:
            for name, threads in [("sqlite", 1), ("tantivy", 2), ("tantivy", 4)]:
                path = Path(directory) / f"{name}-{threads}"
                path.mkdir()
                command = [sys.executable, __file__, "--engine", name, "--path", str(path), "--threads", str(threads)]
                built = subprocess.run(command + ["--corpus", str(args.corpus), "--rounds", str(args.rounds)],
                                       check=True, capture_output=True, text=True)
                report = json.loads(built.stdout)
                reopen = []
                for _ in range(7):
                    start = time.perf_counter()
                    run = subprocess.run(command + ["--reopen"], check=True, capture_output=True, text=True)
                    data = json.loads(run.stdout)
                    data["processWallMs"] = round(milliseconds(start), 3)
                    reopen.append(data)
                report["processColdFilesystemWarm"] = {
                    key: summary([run[key] for run in reopen]) for key in ["openMs", "firstQueryMs", "processWallMs"]}
                report["reopenPeakRssMiB"] = max(run["peakRssMiB"] for run in reopen)
                engines.append(report)
        result = {"environment": {"python": platform.python_version(), "arch": platform.machine(),
                                  "sqlite": sqlite3.sqlite_version, "tantivy": importlib.metadata.version("tantivy")},
                  "rounds": args.rounds, "results": engines,
                  "correctness": "Every measured result equals the independent literal scan in file ID, first page and passage count. Unicode/punctuation probes and immediate replacement visibility also pass.",
                  "limits": "Python engine prototypes using the same pre-normalized synthetic pages. No service refresh or snippets. SQLite uses SQL instr verification; Tantivy uses stored-document decoding and Python literal verification, with constant-score TopDocs because these bindings lack DocSetCollector. Short/common queries require all stored text. No claim about an optimized Rust collector. Process-cold tests retain OS filesystem caches; process wall includes imports and exit. Peak RSS includes interpreter, corpus and indexing; reopen RSS excludes loading the corpus. Build includes commit and merge-thread drain. Seven updates reuse a writer, with its startup measured separately. Tantivy writer heap target is 64 MB; metadata schemas differ."}
        rendered = json.dumps(result, indent=2) + "\n"
        print(rendered, end="")
        if args.output:
            args.output.write_text(rendered)
        return

    cls = SQLiteEngine if args.engine == "sqlite" else TantivyEngine
    if args.engine == "tantivy":
        import tantivy  # Load bindings before the engine-open timer, as for sqlite3.
    if args.reopen:
        start = time.perf_counter()
        engine = cls(args.path, threads=args.threads)
        open_ms = milliseconds(start)
        start = time.perf_counter()
        assert engine.search(["needlemarker"])[0] > 0
        print(json.dumps({"openMs": round(open_ms, 3), "firstQueryMs": round(milliseconds(start), 3), "peakRssMiB": peak_mib()}))
        engine.close()
        return

    corpus = json.loads(args.corpus.read_text())
    baseline_rss = peak_mib()
    cpu = resource.getrusage(resource.RUSAGE_SELF)
    cpu_start = cpu.ru_utime + cpu.ru_stime
    start = time.perf_counter()
    engine = cls(args.path, create=True, threads=args.threads)
    engine.build(corpus)
    build_ms = milliseconds(start)
    cpu = resource.getrusage(resource.RUSAGE_SELF)
    build_cpu_ms = (cpu.ru_utime + cpu.ru_stime - cpu_start) * 1000
    results = []
    for name, terms, scope in CASES:
        expected = oracle(corpus, terms, scope)
        start = time.perf_counter()
        assert engine.search(terms, scope) == expected, (args.engine, name)
        first_ms = milliseconds(start)
        times = []
        for _ in range(args.rounds):
            start = time.perf_counter()
            actual = engine.search(terms, scope)
            times.append(milliseconds(start))
            assert actual == expected, (args.engine, name)
        results.append({"case": name, "matches": expected[0], "firstQueryMs": round(first_ms, 3), **summary(times)})
    size = sum(path.stat().st_size for path in args.path.rglob("*") if path.is_file())
    # Replace an existing document, proving old postings disappear as well.
    previous = corpus[-1]
    writer_start_ms = engine.start_updates()
    updates = []
    for i in range(7):
        token = f"freshvisibilitytoken{i}"
        replacement = {"file": previous["file"], "rows": [{"number": 0, "text": token},
            {"number": 7, "text": "café abc 日本語 😀🐈🐕 c++ x.y [a-z] 100% i\u0307stanbul"}]}
        updates.append(engine.replace(replacement, token))
        corpus[-1] = replacement
        assert engine.search([token]) == oracle(corpus, [token], "")
        if i:
            assert engine.search([f"freshvisibilitytoken{i - 1}"])[0] == 0
    update = {"iterations": len(updates), "writerStartMs": writer_start_ms,
              "commit": summary([row["commitMs"] for row in updates]),
              "visible": summary([row["visibleMs"] for row in updates]),
              "requiresReaderReload": args.engine == "tantivy"}
    for terms in [["freshvisibilitytoken"], ["common"], ["ab"], ["café"], ["abc"], ["日本語"], ["😀🐈🐕"],
                  ["c++", "x.y"], ["[a-z]"], ["100%"], ["i\u0307stanbul"], ["afé a"], ["% i\u0307"]]:
        assert engine.search(terms) == oracle(corpus, terms, ""), (args.engine, terms)
    engine.close()
    print(json.dumps({"engine": args.engine, "indexingThreads": args.threads, "files": len(corpus),
                      "rows": sum(len(entry["rows"]) for entry in corpus) + len(previous["rows"]) - len(replacement["rows"]),
                      "buildMs": round(build_ms, 2), "indexBytes": size, "baselinePeakRssMiB": baseline_rss,
                      "buildCpuMs": round(build_cpu_ms, 2),
                      "peakRssMiB": peak_mib(), "update": update, "queries": results}))


if __name__ == "__main__":
    main()
