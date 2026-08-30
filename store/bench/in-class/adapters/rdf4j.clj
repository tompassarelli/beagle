;; RDF4J NativeStore public-API adapter for the durable sole-writer benchmark.
;; This file is a benchmark-only JVM foreign-system boundary; it copies or
;; derives no RDF4J implementation source.
(require '[cheshire.core :as json])

(import '[java.io File]
        '[java.nio.file Files]
        '[java.util HashSet]
        '[org.eclipse.rdf4j.model IRI Literal Resource Value ValueFactory]
        '[org.eclipse.rdf4j.model.impl SimpleValueFactory]
        '[org.eclipse.rdf4j.query BindingSet QueryLanguage TupleQuery TupleQueryResult]
        '[org.eclipse.rdf4j.repository RepositoryConnection]
        '[org.eclipse.rdf4j.repository.sail SailRepository]
        '[org.eclipse.rdf4j.sail.nativerdf NativeStore])

(set! *warn-on-reflection* true)

(def corpus-triples (Long/parseLong (or (first *command-line-args*) "3000")))
(def run-id (Long/parseLong (or (second *command-line-args*) "1")))
(when-not (and (pos? corpus-triples) (zero? (mod corpus-triples 3)))
  (throw (ex-info "corpus size must be a positive multiple of 3"
                  {:corpus-triples corpus-triples})))

(def expected-rows (quot corpus-triples 3))
(def ^File scratch
  (.toFile
   (Files/createTempDirectory
    "store-in-class-rdf4j-"
    (make-array java.nio.file.attribute.FileAttribute 0))))
(def ^ValueFactory value-factory (SimpleValueFactory/getInstance))
(def base-iri "urn:beagle:store:in-class:")
(def corpus-subject-prefix (str base-iri "corpus/"))
(def write-subject-prefix (str base-iri "write/"))
(def ^IRI kind-predicate (.createIRI value-factory (str base-iri "kind")))
(def ^IRI title-predicate (.createIRI value-factory (str base-iri "title")))
(def ^IRI owner-predicate (.createIRI value-factory (str base-iri "owner")))
(def ^IRI bench-value-predicate
  (.createIRI value-factory (str base-iri "bench-value")))
(def ^Literal thread-value (.createLiteral value-factory "thread"))
(def ^"[Lorg.eclipse.rdf4j.model.Resource;" no-contexts
  (make-array Resource 0))

(def query-text
  (str "SELECT ?s ?title WHERE { "
       "?s <" kind-predicate "> \"thread\" . "
       "?s <" title-predicate "> ?title . "
       "}"))

(defn ms [f]
  (let [started (System/nanoTime)
        value (f)]
    [(/ (- (System/nanoTime) started) 1e6) value]))

(defn ^IRI corpus-subject [index]
  (.createIRI value-factory (str corpus-subject-prefix index)))

(defn ^SailRepository open-repository [^File data-directory]
  (let [^NativeStore store (NativeStore. data-directory)
        ^SailRepository repository (SailRepository. store)]
    ;; NativeStore defaults this off. The benchmark's commit acknowledgment is
    ;; durable only when every repository instance enables it before init.
    (.setForceSync store true)
    (when-not (.getForceSync store)
      (throw (ex-info "RDF4J NativeStore refused forceSync" {})))
    (.init repository)
    repository))

(defn add-statement! [^RepositoryConnection connection
                      ^Resource subject
                      ^IRI predicate
                      ^Value value]
  (.add connection subject predicate value no-contexts))

(defn transactional! [^RepositoryConnection connection f]
  (.begin connection)
  (try
    (let [value (f)]
      (.commit connection)
      value)
    (catch Throwable failure
      (when (.isActive connection)
        (.rollback connection))
      (throw failure))))

(defn seed-corpus! [^RepositoryConnection connection]
  (transactional!
   connection
   (fn []
     (doseq [tx (range 1 (inc corpus-triples))]
       (let [subject-index (quot (dec tx) 3)
             slot (mod (dec tx) 3)
             [^IRI predicate ^Literal value]
             (case slot
               0 [kind-predicate thread-value]
               1 [title-predicate
                  (.createLiteral value-factory (str "title-" subject-index))]
               2 [owner-predicate
                  (.createLiteral value-factory
                                  (str "@owner-" (mod subject-index 32)))])]
         (add-statement! connection (corpus-subject subject-index)
                         predicate value))))))

(defn ^TupleQuery prepare-join [^RepositoryConnection connection]
  (.prepareTupleQuery connection QueryLanguage/SPARQL query-text))

(defn subject-index [^Value subject]
  (when (instance? IRI subject)
    (let [^String text (.stringValue subject)]
      (when (.startsWith text corpus-subject-prefix)
        (try
          (Long/parseLong (subs text (count corpus-subject-prefix)))
          (catch NumberFormatException _ nil))))))

(defn read-join [^TupleQuery query]
  (with-open [^TupleQueryResult result (.evaluate query)]
    (let [^HashSet seen (HashSet.)]
      (loop [rows 0
             invalid 0]
        (if (.hasNext result)
          (let [^BindingSet binding (.next result)
                subject (.getValue binding "s")
                title (.getValue binding "title")
                index (subject-index subject)
                valid? (and (some? index)
                            (<= 0 index)
                            (< index expected-rows)
                            (instance? Literal title)
                            (= (str "title-" index)
                               (.getLabel ^Literal title)))]
            (if (and valid? (.add seen index))
              (recur (inc rows) invalid)
              (recur (inc rows) (inc invalid))))
          {:rows rows
           :errors (+ invalid (- expected-rows (.size seen)))})))))

(def errors (atom 0))

(defn checked-query! [^TupleQuery query]
  (let [result (read-join query)]
    (swap! errors + (:errors result))
    (:rows result)))

(defn durable-write! [^RepositoryConnection connection subject value]
  (transactional!
   connection
   #(add-statement!
     connection
     (.createIRI value-factory (str write-subject-prefix subject))
     bench-value-predicate
     (.createLiteral value-factory (str value)))))

(defn percentile [xs p]
  (let [sorted (vec (sort xs))]
    (nth sorted (min (dec (count sorted))
                     (int (Math/floor (* p (count sorted))))))))

;; Seed is outside every timer, then the durable repository is fully closed.
(def ^SailRepository seed-repository (open-repository scratch))
(with-open [^RepositoryConnection seed-connection
            (.getConnection seed-repository)]
  (seed-corpus! seed-connection))
(.shutDown seed-repository)

;; Boot includes NativeStore open/recovery, connection creation, and a known
;; corpus probe. It excludes JVM startup and untimed seeding.
(def boot-start (System/nanoTime))
(def ^SailRepository repository (open-repository scratch))
(def ^RepositoryConnection writer (.getConnection repository))
(when-not (.hasStatement writer (corpus-subject 0) kind-predicate thread-value
                         false no-contexts)
  (throw (ex-info "adapter-ready probe failed" {})))
(def boot-elapsed (/ (- (System/nanoTime) boot-start) 1e6))

(def ^RepositoryConnection steady-reader (.getConnection repository))
(def ^TupleQuery steady-query (prepare-join steady-reader))

(def cold
  (let [[elapsed rows] (ms #(checked-query! steady-query))]
    {:ms elapsed :rows rows}))

(dotimes [i 30]
  (durable-write! writer (str "warm-" i) (str "warm-" i)))
(dotimes [_ 10]
  (checked-query! steady-query))

(def sustained
  (let [stop? (atom false)
        reads (atom 0)
        reader
        (future
          (with-open [^RepositoryConnection connection
                      (.getConnection repository)]
            (let [^TupleQuery query (prepare-join connection)]
              (while (not @stop?)
                (checked-query! query)
                (swap! reads inc)))))
        [elapsed _]
        (try
          (ms #(dotimes [i 1200]
                 (durable-write! writer
                                 (str "sustained-" run-id "-" i)
                                 (str "value-" i))))
          (finally
            (reset! stop? true)
            @reader))]
    (when (zero? @reads)
      (swap! errors inc))
    {:ops-s (/ 1200.0 (/ elapsed 1000.0))
     :read-ops @reads}))

(def mixed
  (let [read-latencies (atom [])
        [elapsed _]
        (ms #(dotimes [i 40]
               (durable-write! writer
                               (str "mixed-" run-id "-" i)
                               (str "value-" i))
               (dotimes [_ 3]
                 (let [[read-ms _] (ms (fn []
                                         (checked-query! steady-query)))]
                   (swap! read-latencies conj read-ms)))))]
    {:ops-s (/ 160.0 (/ elapsed 1000.0))
     :read-p50-ms (percentile @read-latencies 0.50)}))

(def row
  {:adapter "rdf4j-nativestore"
   :run run-id
   :corpus-triples corpus-triples
   :boot-to-serving-ms boot-elapsed
   :cold-start-query-ms (:ms cold)
   :cold-query-rows (:rows cold)
   :write-under-read-ops-s (:ops-s sustained)
   :concurrent-read-ops (:read-ops sustained)
   :mixed-ops-s (:ops-s mixed)
   :mixed-read-p50-ms (:read-p50-ms mixed)
   :errors @errors})

(println "BENCHROW" (json/generate-string row))

(.close steady-reader)
(.close writer)
(.shutDown repository)
(doseq [^File file (reverse (file-seq scratch))]
  (.delete file))
(shutdown-agents)
