(ns store.types
  (:require [store.slots :as slots]))

(defrecord Instant [epoch-seconds nanos])

(defn instant-epoch-seconds [r] (:epoch-seconds r))

(defn instant-nanos [r] (:nanos r))

(defn ^Boolean instant? [v]
  (instance? Instant v))

(defn ^Instant instant [epoch-seconds nanos]
  (if (and (>= nanos 0) (< nanos 1000000000)) (->Instant epoch-seconds nanos) (throw (ex-info "store: instant nanoseconds must be in [0, 1000000000)" {:type :invalid-instant}))))

(defn ^Instant instant-shift-seconds [^Instant at seconds]
  (->Instant (+ (instant-epoch-seconds at) seconds) (instant-nanos at)))

(defn instant-seconds-between [^Instant earlier ^Instant later]
  (- (instant-epoch-seconds later) (instant-epoch-seconds earlier)))

(defrecord Triple [t1 t2 t3])

(defn triple-t1 [r] (:t1 r))

(defn triple-t2 [r] (:t2 r))

(defn triple-t3 [r] (:t3 r))

(defrecord RpcPageRequest [limit cursor])

(defn rpcpagerequest-limit [r] (:limit r))

(defn rpcpagerequest-cursor [r] (:cursor r))

(defrecord RpcPageResponse [ordinal next-cursor done])

(defn rpcpageresponse-ordinal [r] (:ordinal r))

(defn rpcpageresponse-next-cursor [r] (:next-cursor r))

(defn rpcpageresponse-done [r] (:done r))

(defrecord RpcError [code retryable message detail])

(defn rpcerror-code [r] (:code r))

(defn rpcerror-retryable [r] (:retryable r))

(defn rpcerror-message [r] (:message r))

(defn rpcerror-detail [r] (:detail r))

(defrecord RpcRequest [space op expected-version page timeout-ms payload])

(defn rpcrequest-space [r] (:space r))

(defn rpcrequest-op [r] (:op r))

(defn rpcrequest-expected-version [r] (:expected-version r))

(defn rpcrequest-page [r] (:page r))

(defn rpcrequest-timeout-ms [r] (:timeout-ms r))

(defn rpcrequest-payload [r] (:payload r))

(defrecord RpcResponse [space op served-version page error payload])

(defn rpcresponse-space [r] (:space r))

(defn rpcresponse-op [r] (:op r))

(defn rpcresponse-served-version [r] (:served-version r))

(defn rpcresponse-page [r] (:page r))

(defn rpcresponse-error [r] (:error r))

(defn rpcresponse-payload [r] (:payload r))

(defrecord StoreRpcPacketV2 [kind flags request-id request response])

(defn storerpcpacketv2-kind [r] (:kind r))

(defn storerpcpacketv2-flags [r] (:flags r))

(defn storerpcpacketv2-request-id [r] (:request-id r))

(defn storerpcpacketv2-request [r] (:request r))

(defn storerpcpacketv2-response [r] (:response r))

(defrecord TermCodecMeasure [bytes nodes])

(defn termcodecmeasure-bytes [r] (:bytes r))

(defn termcodecmeasure-nodes [r] (:nodes r))

(defrecord TermCodecDecoded [value nodes])

(defn termcodecdecoded-value [r] (:value r))

(defn termcodecdecoded-nodes [r] (:nodes r))

(defn ^Boolean triple? [v]
  (instance? Triple v))

(defn ^Boolean rpc-page-request? [v]
  (instance? RpcPageRequest v))

(defn ^Boolean rpc-page-response? [v]
  (instance? RpcPageResponse v))

(defn ^Boolean rpc-error? [v]
  (instance? RpcError v))

(defn ^Boolean rpc-request? [v]
  (instance? RpcRequest v))

(defn ^Boolean rpc-response? [v]
  (instance? RpcResponse v))

(defn ^Boolean store-rpc-packet-v2? [v]
  (instance? StoreRpcPacketV2 v))

(defn rpc-page-request-cursor-value [^RpcPageRequest v]
  (rpcpagerequest-cursor v))

(defn rpc-page-response-cursor-value [^RpcPageResponse v]
  (rpcpageresponse-next-cursor v))

(defn rpc-error-detail-value [^RpcError v]
  (rpcerror-detail v))

(defn rpc-request-payload-value [^RpcRequest v]
  (rpcrequest-payload v))

(defn rpc-response-payload-value [^RpcResponse v]
  (rpcresponse-payload v))

(defrecord AtomRow [kind string-value int-value float-value bool-value keyword-value instant-value])

(defn atomrow-kind [r] (:kind r))

(defn atomrow-string-value [r] (:string-value r))

(defn atomrow-int-value [r] (:int-value r))

(defn atomrow-float-value [r] (:float-value r))

(defn atomrow-bool-value [r] (:bool-value r))

(defn atomrow-keyword-value [r] (:keyword-value r))

(defn atomrow-instant-value [r] (:instant-value r))

(defrecord TripleRow [t1 t2 t3])

(defn triplerow-t1 [r] (:t1 r))

(defn triplerow-t2 [r] (:t2 r))

(defn triplerow-t3 [r] (:t3 r))

(defrecord TransactionRow [sequence first-operation operation-count])

(defn transactionrow-sequence [r] (:sequence r))

(defn transactionrow-first-operation [r] (:first-operation r))

(defn transactionrow-operation-count [r] (:operation-count r))

(defrecord OperationRow [tx-sequence ordinal action triple-handle])

(defn operationrow-tx-sequence [r] (:tx-sequence r))

(defn operationrow-ordinal [r] (:ordinal r))

(defn operationrow-action [r] (:action r))

(defn operationrow-triple-handle [r] (:triple-handle r))

(defrecord ActiveBucket [triple-handle prefix-count positions])

(defn activebucket-triple-handle [r] (:triple-handle r))

(defn activebucket-prefix-count [r] (:prefix-count r))

(defn activebucket-positions [r] (:positions r))

(defrecord CommitOperation [action proposition])

(defn commitoperation-action [r] (:action r))

(defn commitoperation-proposition [r] (:proposition r))

(defrecord CommitValidationAttestation [validator result attestation])

(defn commitvalidationattestation-validator [r] (:validator r))

(defn commitvalidationattestation-result [r] (:result r))

(defn commitvalidationattestation-attestation [r] (:attestation r))

(defrecord CommitMetadata [producer shape-schema-id profile validation-attestation])

(defn commitmetadata-producer [r] (:producer r))

(defn commitmetadata-shape-schema-id [r] (:shape-schema-id r))

(defn commitmetadata-profile [r] (:profile r))

(defn commitmetadata-validation-attestation [r] (:validation-attestation r))

(defrecord TransactionRecord [sequence operations])

(defn transactionrecord-sequence [r] (:sequence r))

(defn transactionrecord-operations [r] (:operations r))

(defrecord OperationOccurrence [coordinate action proposition])

(defn operationoccurrence-coordinate [r] (:coordinate r))

(defn operationoccurrence-action [r] (:action r))

(defn operationoccurrence-proposition [r] (:proposition r))

(defrecord Withdrawal [retraction assertion])

(defn withdrawal-retraction [r] (:retraction r))

(defn withdrawal-assertion [r] (:assertion r))

(defrecord TermStore [space-id next-sequence atoms triples transactions operations withdrawal-targets active-buckets active-cells fold-open atom-slots triple-slots triple-t1-slots triple-t12-slots triple-t2-slots triple-t3-slots active-slots packed-prefix tail-row-limit tail-byte-limit tail-bytes tail-rollovers])

(defn termstore-space-id [r] (:space-id r))

(defn termstore-next-sequence [r] (:next-sequence r))

(defn termstore-atoms [r] (:atoms r))

(defn termstore-triples [r] (:triples r))

(defn termstore-transactions [r] (:transactions r))

(defn termstore-operations [r] (:operations r))

(defn termstore-withdrawal-targets [r] (:withdrawal-targets r))

(defn termstore-active-buckets [r] (:active-buckets r))

(defn termstore-active-cells [r] (:active-cells r))

(defn termstore-fold-open [r] (:fold-open r))

(defn termstore-atom-slots [r] (:atom-slots r))

(defn termstore-triple-slots [r] (:triple-slots r))

(defn termstore-triple-t1-slots [r] (:triple-t1-slots r))

(defn termstore-triple-t12-slots [r] (:triple-t12-slots r))

(defn termstore-triple-t2-slots [r] (:triple-t2-slots r))

(defn termstore-triple-t3-slots [r] (:triple-t3-slots r))

(defn termstore-active-slots [r] (:active-slots r))

(defn termstore-packed-prefix [r] (:packed-prefix r))

(defn termstore-tail-row-limit [r] (:tail-row-limit r))

(defn termstore-tail-byte-limit [r] (:tail-byte-limit r))

(defn termstore-tail-bytes [r] (:tail-bytes r))

(defn termstore-tail-rollovers [r] (:tail-rollovers r))

(defrecord TermStoreDump [version space-id next-sequence atoms triples transactions operations])

(defn termstoredump-version [r] (:version r))

(defn termstoredump-space-id [r] (:space-id r))

(defn termstoredump-next-sequence [r] (:next-sequence r))

(defn termstoredump-atoms [r] (:atoms r))

(defn termstoredump-triples [r] (:triples r))

(defn termstoredump-transactions [r] (:transactions r))

(defn termstoredump-operations [r] (:operations r))

(defn ^Boolean commit-operation? [v]
  (instance? CommitOperation v))

(defn ^Boolean commit-validation-attestation? [v]
  (instance? CommitValidationAttestation v))

(defn ^Boolean commit-metadata? [v]
  (instance? CommitMetadata v))

(defn ^Boolean transaction-record? [v]
  (instance? TransactionRecord v))

(defn ^Boolean term-store-dump? [v]
  (instance? TermStoreDump v))

(defn ^Boolean operation-occurrence? [v]
  (instance? OperationOccurrence v))

(defn ^Boolean withdrawal? [v]
  (instance? Withdrawal v))

(def tx-sequence :kernel/tx-sequence)

(def op-ordinal :kernel/op-ordinal)

(def recorded-at-predicate :kernel/recorded-at)

(def assert-action :assert)

(def retract-action :retract)

(defn ^Boolean atom? [v]
  (or (string? v) (or (integer? v) (or (and (number? v) (not (integer? v))) (or (boolean? v) (or (keyword? v) (instant? v)))))))

(defn ^Boolean term? [v]
  (if (triple? v) (and (term? (triple-t1 v)) (and (term? (triple-t2 v)) (term? (triple-t3 v)))) (atom? v)))

(defn term-as-triple [v]
  (let [candidate v]
  (if (and (triple? candidate) (term? candidate)) candidate nil)))

(defn ^Triple triple [t1 t2 t3]
  (let [value (->Triple t1 t2 t3)]
  (if (term? value) value (throw (ex-info "store: triple contains a value outside Term" {:type :invalid-term})))))

(defn ^Triple transaction-coordinate [^String space-id sequence]
  (if (and (pos? (count space-id)) (>= sequence 0)) (triple space-id tx-sequence sequence) (throw (ex-info "store: transaction coordinate requires a non-empty space and non-negative sequence" {:type :invalid-transaction-coordinate}))))

(defn ^Boolean transaction-coordinate? [v]
  (and (triple? v) (and (string? (triple-t1 v)) (and (pos? (count (triple-t1 v))) (and (= tx-sequence (triple-t2 v)) (and (integer? (triple-t3 v)) (>= (triple-t3 v) 0)))))))

(defn ^Triple occurrence-coordinate [^Triple tx ordinal]
  (if (and (transaction-coordinate? tx) (>= ordinal 0)) (triple tx op-ordinal ordinal) (throw (ex-info "store: occurrence coordinate requires a transaction coordinate and non-negative ordinal" {:type :invalid-occurrence-coordinate}))))

(defn ^Boolean occurrence-coordinate? [v]
  (and (triple? v) (and (transaction-coordinate? (triple-t1 v)) (and (= op-ordinal (triple-t2 v)) (and (integer? (triple-t3 v)) (>= (triple-t3 v) 0))))))

(defn ^Triple recorded-at [^Triple source ^Instant at]
  (if (and (triple? source) (instant? at)) (triple source recorded-at-predicate at) (throw (ex-info "store: recorded-at requires a triple source and Instant" {:type :invalid-recorded-at}))))

(defn ^Boolean occurrence-before? [^Triple left ^Triple right]
  (if (and (occurrence-coordinate? left) (occurrence-coordinate? right)) (let [left-tx (triple-t1 left)
   right-tx (triple-t1 right)
   left-space (triple-t1 left-tx)
   right-space (triple-t1 right-tx)
   left-seq (triple-t3 left-tx)
   right-seq (triple-t3 right-tx)
   left-ordinal (triple-t3 left)
   right-ordinal (triple-t3 right)]
  (if (= left-space right-space) (or (< left-seq right-seq) (and (= left-seq right-seq) (< left-ordinal right-ordinal))) (throw (ex-info "store: occurrences from different spaces have no shared order" {:type :incomparable-occurrence-spaces})))) (throw (ex-info "store: occurrence ordering requires occurrence coordinates" {:type :invalid-occurrence-order}))))

(defn ^OperationOccurrence operation-occurrence [^Triple coordinate action ^Triple proposition]
  (if (and (occurrence-coordinate? coordinate) (and (or (= assert-action action) (= retract-action action)) (and (triple? proposition) (term? proposition)))) (->OperationOccurrence coordinate action proposition) (throw (ex-info "store: operation occurrence requires a coordinate, action, and Triple proposition" {:type :invalid-operation-occurrence}))))

(defn ^Boolean assertion-occurrence? [value]
  (and (operation-occurrence? value) (and (occurrence-coordinate? (operationoccurrence-coordinate value)) (and (= assert-action (operationoccurrence-action value)) (and (triple? (operationoccurrence-proposition value)) (term? (operationoccurrence-proposition value)))))))

(defn ^Boolean retraction-occurrence? [value]
  (and (operation-occurrence? value) (and (occurrence-coordinate? (operationoccurrence-coordinate value)) (and (= retract-action (operationoccurrence-action value)) (and (triple? (operationoccurrence-proposition value)) (term? (operationoccurrence-proposition value)))))))

(defn ^Withdrawal withdrawal [^OperationOccurrence retraction ^OperationOccurrence assertion]
  (let [retraction-coordinate (operationoccurrence-coordinate retraction)
   assertion-coordinate (operationoccurrence-coordinate assertion)]
  (if (and (retraction-occurrence? retraction) (assertion-occurrence? assertion)) (let [retraction-transaction (triple-t1 retraction-coordinate)
   assertion-transaction (triple-t1 assertion-coordinate)]
  (if (and (= (operationoccurrence-proposition retraction) (operationoccurrence-proposition assertion)) (and (= (triple-t1 retraction-transaction) (triple-t1 assertion-transaction)) (occurrence-before? assertion-coordinate retraction-coordinate))) (->Withdrawal retraction assertion) (throw (ex-info "store: withdrawal requires a later retraction of the same asserted proposition" {:type :invalid-withdrawal})))) (throw (ex-info "store: withdrawal requires a later retraction of the same asserted proposition" {:type :invalid-withdrawal})))))
