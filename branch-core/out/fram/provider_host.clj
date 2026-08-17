(ns fram.provider-host
  (:require [fram.types :as t]
            [fram.rt :as rt]))

(defrecord ProviderDescriptor [identity capability contract imports boot-result])

(defn providerdescriptor-identity [r] (:identity r))

(defn providerdescriptor-capability [r] (:capability r))

(defn providerdescriptor-contract [r] (:contract r))

(defn providerdescriptor-imports [r] (:imports r))

(defn providerdescriptor-boot-result [r] (:boot-result r))

(defrecord ProviderViolation [code capability identity detail])

(defn providerviolation-code [r] (:code r))

(defn providerviolation-capability [r] (:capability r))

(defn providerviolation-identity [r] (:identity r))

(defn providerviolation-detail [r] (:detail r))

(defrecord ProviderStage [capability stage result])

(defn providerstage-capability [r] (:capability r))

(defn providerstage-stage [r] (:stage r))

(defn providerstage-result [r] (:result r))

(defrecord ProviderBoot [providers violations stages])

(defn providerboot-providers [r] (:providers r))

(defn providerboot-violations [r] (:violations r))

(defn providerboot-stages [r] (:stages r))

(defrecord ProviderAction [operation proposition policy])

(defn provideraction-operation [r] (:operation r))

(defn provideraction-proposition [r] (:proposition r))

(defn provideraction-policy [r] (:policy r))

(defrecord ProviderBatch [space expected-version actions])

(defn providerbatch-space [r] (:space r))

(defn providerbatch-expected-version [r] (:expected-version r))

(defn providerbatch-actions [r] (:actions r))

(defrecord ProviderPlan [accepted code result expected-version actions stages])

(defn providerplan-accepted [r] (:accepted r))

(defn providerplan-code [r] (:code r))

(defn providerplan-result [r] (:result r))

(defn providerplan-expected-version [r] (:expected-version r))

(defn providerplan-actions [r] (:actions r))

(defn providerplan-stages [r] (:stages r))

(defn capability [^String domain major]
  (if (and (pos? (count domain)) (pos? major)) (t/triple :provider/capability domain major) (throw (ex-info "provider capability requires a non-empty domain and positive major" {:type :provider/invalid-capability}))))

(defn provider-identity [capability-value ^String implementation]
  (if (pos? (count implementation)) (t/triple capability-value :provider/implementation implementation) (throw (ex-info "provider identity requires a non-empty implementation" {:type :provider/invalid-identity}))))

(defn provider-contract [capability-value major]
  (if (pos? major) (t/triple capability-value :provider/contract major) (throw (ex-info "provider contract major must be positive" {:type :provider/invalid-contract}))))

(defn ^ProviderDescriptor descriptor [identity capability-value contract imports boot-result]
  (->ProviderDescriptor identity capability-value contract imports boot-result))

(defn providers-for [descriptors capability-value]
  (filterv (fn [^ProviderDescriptor value] (= capability-value (providerdescriptor-capability value))) descriptors))

(defn identity-count [descriptors identity]
  (count (filterv (fn [^ProviderDescriptor value] (= identity (providerdescriptor-identity value))) descriptors)))

(defn ^Boolean capability-enabled? [enabled capability-value]
  (boolean (some (fn [value] (= capability-value value)) enabled)))

(defn ^ProviderViolation violation [code ^ProviderDescriptor descriptor-value detail]
  (->ProviderViolation code (providerdescriptor-capability descriptor-value) (providerdescriptor-identity descriptor-value) detail))

(defn ^Boolean contract-valid? [^ProviderDescriptor descriptor-value]
  (let [contract (providerdescriptor-contract descriptor-value)]
  (and (= (providerdescriptor-capability descriptor-value) (t/triple-t1 contract)) (and (= :provider/contract (t/triple-t2 contract)) (and (integer? (t/triple-t3 contract)) (pos? (t/triple-t3 contract)))))))

(defn import-violations [^ProviderDescriptor descriptor-value selected]
  (reduce (fn [violations imported] (if (= 1 (count (providers-for selected imported))) violations (conj violations (violation :provider/import-unavailable descriptor-value (t/triple imported :provider/required-by (providerdescriptor-identity descriptor-value)))))) [] (providerdescriptor-imports descriptor-value)))

(defn descriptor-violations [^ProviderDescriptor descriptor-value selected]
  (let [v0 []
   v1 (if (= 1 (identity-count selected (providerdescriptor-identity descriptor-value))) v0 (conj v0 (violation :provider/duplicate-identity descriptor-value (t/triple (providerdescriptor-identity descriptor-value) :provider/count (identity-count selected (providerdescriptor-identity descriptor-value))))))
   v2 (if (contract-valid? descriptor-value) v1 (conj v1 (violation :provider/invalid-contract descriptor-value (providerdescriptor-contract descriptor-value))))
   v3 (if (= :provider/ready (providerdescriptor-boot-result descriptor-value)) v2 (conj v2 (violation :provider/boot-rejected descriptor-value (t/triple (providerdescriptor-identity descriptor-value) :provider/boot-result (providerdescriptor-boot-result descriptor-value)))))]
  (into v3 (import-violations descriptor-value selected))))

(defn selection-violations [descriptors enabled]
  (reduce (fn [violations capability-value] (let [matches (providers-for descriptors capability-value)]
  (if (= 1 (count matches)) violations (conj violations (->ProviderViolation :provider/capability-cardinality capability-value (provider-identity capability-value "selection") (t/triple capability-value :provider/count (count matches))))))) [] enabled))

(defn selected-providers [descriptors enabled]
  (reduce (fn [selected capability-value] (let [matches (providers-for descriptors capability-value)]
  (if (= 1 (count matches)) (conj selected (first matches)) selected))) [] enabled))

(defn ^ProviderBoot boot-providers [descriptors enabled]
  (let [selected (selected-providers descriptors enabled)
   initial (selection-violations descriptors enabled)
   violations (reduce (fn [current ^ProviderDescriptor descriptor-value] (into current (descriptor-violations descriptor-value selected))) initial selected)
   stages (mapv (fn [capability-value] (->ProviderStage capability-value :provider/boot (if (empty? violations) :provider/ready :provider/rejected))) enabled)]
  (->ProviderBoot (if (empty? violations) selected []) violations stages)))

(defn ^Boolean boot-ok? [^ProviderBoot boot]
  (empty? (providerboot-violations boot)))

(defn ^ProviderDescriptor provider-for [^ProviderBoot boot capability-value]
  (let [matches (providers-for (providerboot-providers boot) capability-value)]
  (if (and (boot-ok? boot) (= 1 (count matches))) (first matches) (throw (ex-info "provider capability was not selected at boot" {:type :provider/not-selected})))))

(defn ^ProviderAction provider-action [operation proposition policy]
  (if (and (or (= operation :rpc/assert) (= operation :rpc/retract)) (or (= policy :rpc/subject-any) (= policy :rpc/subject-existing))) (->ProviderAction operation proposition policy) (throw (ex-info "provider action is outside the FRAMRPC mutation seam" {:type :provider/invalid-action}))))

(defn ^ProviderStage provider-stage [capability-value stage result]
  (->ProviderStage capability-value stage result))

(defn ^ProviderPlan accepted-plan [result expected-version actions stages]
  (if (and (>= expected-version 0) (pos? (count actions))) (->ProviderPlan true :provider/accepted result expected-version actions stages) (throw (ex-info "accepted provider plan requires an expected version and actions" {:type :provider/invalid-plan}))))

(defn ^ProviderPlan rejected-plan [code result expected-version stages]
  (->ProviderPlan false code result expected-version [] stages))

(defn ^ProviderBatch provider-batch [^String space expected-version actions]
  (if (and (pos? (count space)) (and (>= expected-version 0) (pos? (count actions)))) (->ProviderBatch space expected-version actions) (throw (ex-info "provider batch requires space, expected version, and actions" {:type :provider/invalid-batch}))))

(defn rpc-list-term [values]
  (reduce (fn [tail value] (if (t/term? value) (t/triple :rpc/list value tail) (throw (ex-info "provider RPC list contains a value outside Term" {:type :provider/invalid-rpc-term})))) :rpc/list-end (reverse values)))

(defn rpc-record-term [tag fields]
  (t/triple tag (rpc-list-term fields) :rpc/record))

(defn action-term [^ProviderAction action]
  (rpc-record-term :rpc/action [(provideraction-operation action) (provideraction-proposition action) (provideraction-policy action)]))

(defn batch-payload [^ProviderBatch batch]
  (let [actions (mapv (fn [^ProviderAction action] (action-term action)) (providerbatch-actions batch))]
  (rpc-record-term :rpc/batch [(rpc-list-term actions) :rpc/none])))

(defn batch-request [^ProviderBatch batch]
  (t/->RpcRequest (providerbatch-space batch) :rpc/batch (providerbatch-expected-version batch) nil nil (batch-payload batch)))

(defn plan-batch [^String space ^ProviderPlan plan]
  (if (providerplan-accepted plan) (provider-batch space (providerplan-expected-version plan) (providerplan-actions plan)) nil))

(defn plan-request [^String space ^ProviderPlan plan]
  (let [batch (plan-batch space plan)]
  (if batch (batch-request batch) nil)))

(defrecord ProviderInvocation [descriptor request response])

(defn providerinvocation-descriptor [r] (:descriptor r))

(defn providerinvocation-request [r] (:request r))

(defn providerinvocation-response [r] (:response r))

(defn ^Boolean plan-capability? [^ProviderPlan plan capability-value]
  (let [stages (providerplan-stages plan)]
  (and (pos? (count stages)) (every? (fn [^ProviderStage stage] (= capability-value (providerstage-capability stage))) stages))))

(defn ^Boolean response-matches-request? [request response]
  (and (= (t/rpcrequest-space request) (t/rpcresponse-space response)) (= (t/rpcrequest-op request) (t/rpcresponse-op response))))

(defn ^ProviderInvocation invoke-plan-with! [descriptors enabled capability-value ^String space ^ProviderPlan plan executor]
  (let [boot (boot-providers descriptors enabled)
   descriptor-value (provider-for boot capability-value)]
  (cond
  (not (providerplan-accepted plan)) (throw (ex-info "provider invocation refuses a rejected plan" {:type :provider/plan-rejected}))
  (not (plan-capability? plan capability-value)) (throw (ex-info "provider plan capability does not match the boot-selected provider" {:type :provider/capability-mismatch}))
  :else (let [request (plan-request space plan)]
  (if request (let [response (executor request)]
  (if (and (t/rpc-response? response) (response-matches-request? request response)) (->ProviderInvocation descriptor-value request response) (throw (ex-info "provider executor returned a mismatched FRAMRPC response" {:type :provider/response-mismatch})))) (throw (ex-info "accepted provider plan did not lower to FRAMRPC" {:type :provider/request-missing})))))))

(defn ^ProviderInvocation invoke-plan-to! [descriptors enabled capability-value ^String address port ^String space ^ProviderPlan plan]
  (invoke-plan-with! descriptors enabled capability-value space plan (fn [request] (rt/native-request-to! address port request))))
