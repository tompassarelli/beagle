(ns store.rpc-subscription
  (:require [store.rpc :as rpc]
            [store.types :as t])
  (:import [java.util.concurrent ArrayBlockingQueue]
           [java.util.concurrent TimeUnit]))

(def subscription-max-lease-ms 86400000)

(def subscription-handoff-capacity 1)

(def subscription-event-operation :rpc/subscription-event)

(def SubscriptionPhase-values #{::opening ::active ::retired})

(def SubscriptionRetirement-values #{::lease-expired ::disconnected ::adapter-failed ::store-changed ::registry-reset})

(def disconnected-retirement :disconnected)

(def adapter-failed-retirement :adapter-failed)

(defrecord StoreCoordinate [incarnation store-generation space version transaction])

(defn storecoordinate-incarnation [r] (:incarnation r))

(defn storecoordinate-store-generation [r] (:store-generation r))

(defn storecoordinate-space [r] (:space r))

(defn storecoordinate-version [r] (:version r))

(defn storecoordinate-transaction [r] (:transaction r))

(defrecord SubscriptionCursor [generation coordinate])

(defn subscriptioncursor-generation [r] (:generation r))

(defn subscriptioncursor-coordinate [r] (:coordinate r))

(defrecord SubscriptionNotice [acknowledged observed])

(defn subscriptionnotice-acknowledged [r] (:acknowledged r))

(defn subscriptionnotice-observed [r] (:observed r))

(defrecord SubscriptionGeneration [generation opened acknowledged offered delivered lease-deadline-ns phase retirement handoff])

(defn subscriptiongeneration-generation [r] (:generation r))

(defn subscriptiongeneration-opened [r] (:opened r))

(defn subscriptiongeneration-acknowledged [r] (:acknowledged r))

(defn subscriptiongeneration-offered [r] (:offered r))

(defn subscriptiongeneration-delivered [r] (:delivered r))

(defn subscriptiongeneration-lease-deadline-ns [r] (:lease-deadline-ns r))

(defn subscriptiongeneration-phase [r] (:phase r))

(defn subscriptiongeneration-retirement [r] (:retirement r))

(defn subscriptiongeneration-handoff [r] (:handoff r))

(defrecord SubscriptionRegistry [lock coordinate generations next-generation last-now-ns now-ns])

(defn subscriptionregistry-lock [r] (:lock r))

(defn subscriptionregistry-coordinate [r] (:coordinate r))

(defn subscriptionregistry-generations [r] (:generations r))

(defn subscriptionregistry-next-generation [r] (:next-generation r))

(defn subscriptionregistry-last-now-ns [r] (:last-now-ns r))

(defn subscriptionregistry-now-ns [r] (:now-ns r))

(defrecord SubscriptionSession [registry generation])

(defn subscriptionsession-registry [r] (:registry r))

(defn subscriptionsession-generation [r] (:generation r))

;; SubscriptionCommand = OpenSubscription | AcknowledgeSubscription
(defrecord OpenSubscription [resume lease-ms])

(defn opensubscription-resume [r] (:resume r))

(defn opensubscription-lease-ms [r] (:lease-ms r))
(defrecord AcknowledgeSubscription [cursor])

(defn acknowledgesubscription-cursor [r] (:cursor r))

;; SubscriptionOutcome = SubscriptionOpened | SubscriptionAcknowledged
(defrecord SubscriptionOpened [acknowledged observed lease-deadline-ns])

(defn subscriptionopened-acknowledged [r] (:acknowledged r))

(defn subscriptionopened-observed [r] (:observed r))

(defn subscriptionopened-lease-deadline-ns [r] (:lease-deadline-ns r))
(defrecord SubscriptionAcknowledged [cursor observed])

(defn subscriptionacknowledged-cursor [r] (:cursor r))

(defn subscriptionacknowledged-observed [r] (:observed r))

(def subscription-operations #{:rpc/subscribe :rpc/subscription-ack})

(defn- subscription-fail! [code ^String message]
  (throw (ex-info message {:type code :store/code code :code code})))

(defn- ^String require-nonempty-string! [value ^String label]
  (if (and (string? value) (not (empty? value))) value (subscription-fail! :rpc/invalid-subscription (str label " must be a nonempty String"))))

(defn- require-nonnegative-int! [value ^String label]
  (if (and (integer? value) (>= value 0)) value (subscription-fail! :rpc/invalid-subscription (str label " must be a nonnegative Int"))))

(defn- require-transaction-coordinate! [value ^String label]
  (if (t/transaction-coordinate? value) value (subscription-fail! :rpc/invalid-subscription (str label " must be a Store transaction coordinate"))))

(defn- require-lease-ms! [value]
  (if (and (integer? value) (and (> value 0) (<= value subscription-max-lease-ms))) value (subscription-fail! :rpc/invalid-subscription (str "subscription lease-ms must be in [1," subscription-max-lease-ms "]"))))

(defn ^StoreCoordinate store-coordinate! [^String incarnation store-generation ^String space version]
  (let [^String exact-incarnation (require-nonempty-string! incarnation "Store incarnation")
   exact-generation (require-nonnegative-int! store-generation "Store generation")
   ^String exact-space (require-nonempty-string! space "Store space")
   exact-version (require-nonnegative-int! version "Store version")
   transaction (t/transaction-coordinate exact-space exact-version)]
  (->StoreCoordinate exact-incarnation exact-generation exact-space exact-version transaction)))

(defn store-coordinate-wire! [^StoreCoordinate coordinate]
  (rpc/rpc-subscription-coordinate! (storecoordinate-incarnation coordinate) (storecoordinate-store-generation coordinate) (storecoordinate-transaction coordinate)))

(defn ^StoreCoordinate wire-store-coordinate! [value]
  (let [[incarnation-value generation-value transaction-value] (rpc/rpc-subscription-coordinate-fields! value)
   ^String incarnation (require-nonempty-string! incarnation-value "Store incarnation")
   store-generation (require-nonnegative-int! generation-value "Store generation")
   transaction (require-transaction-coordinate! transaction-value "subscription transaction")
   space-value (t/triple-t1 transaction)
   version-value (t/triple-t3 transaction)
   ^String space (require-nonempty-string! space-value "Store space")
   version (require-nonnegative-int! version-value "Store version")
   ^StoreCoordinate coordinate (store-coordinate! incarnation store-generation space version)]
  (if (= transaction (storecoordinate-transaction coordinate)) coordinate (subscription-fail! :rpc/invalid-subscription "subscription transaction is not canonical"))))

(defn cursor-wire! [^SubscriptionCursor cursor]
  (rpc/rpc-subscription-cursor! (subscriptioncursor-generation cursor) (store-coordinate-wire! (subscriptioncursor-coordinate cursor))))

(defn ^SubscriptionCursor wire-cursor! [value]
  (let [[generation-value coordinate-value] (rpc/rpc-subscription-cursor-fields! value)
   ^String generation (require-nonempty-string! generation-value "subscription generation")
   ^StoreCoordinate coordinate (wire-store-coordinate! coordinate-value)]
  (->SubscriptionCursor generation coordinate)))

(defn ^Boolean subscription-operation? [operation]
  (contains? subscription-operations operation))

(defn ^Boolean same-store-history? [^StoreCoordinate left ^StoreCoordinate right]
  (and (= (storecoordinate-incarnation left) (storecoordinate-incarnation right)) (and (= (storecoordinate-store-generation left) (storecoordinate-store-generation right)) (= (storecoordinate-space left) (storecoordinate-space right)))))

(defn ^Boolean coordinate-before? [^StoreCoordinate left ^StoreCoordinate right]
  (and (same-store-history? left right) (< (storecoordinate-version left) (storecoordinate-version right))))

(defn ^Boolean coordinate-at-or-before? [^StoreCoordinate left ^StoreCoordinate right]
  (and (same-store-history? left right) (<= (storecoordinate-version left) (storecoordinate-version right))))

(defn ^SubscriptionRegistry new-registry! [^StoreCoordinate coordinate now-ns]
  (->SubscriptionRegistry (Object.) (atom coordinate) (atom {}) (atom 0) (atom nil) now-ns))

(defn ^SubscriptionSession new-session [^SubscriptionRegistry registry]
  (->SubscriptionSession registry (atom nil)))

(defn ^StoreCoordinate current-coordinate [^SubscriptionRegistry registry]
  (deref (subscriptionregistry-coordinate registry)))

(defn- registry-now-ns-under-lock! [^SubscriptionRegistry registry]
  (let [now ((subscriptionregistry-now-ns registry))
   previous (deref (subscriptionregistry-last-now-ns registry))]
  (if (and previous (< now previous)) (do
  (subscription-fail! :rpc/subscription-clock-regressed "subscription monotonic clock regressed")))
  (reset! (subscriptionregistry-last-now-ns registry) now)
  now))

(defn- session-generation [^SubscriptionSession session]
  (deref (subscriptionsession-generation session)))

(defn- ^Boolean live-phase? [phase]
  (or (= phase :opening) (= phase :active)))

(defn- ^Boolean generation-live? [^SubscriptionGeneration state]
  (live-phase? (deref (subscriptiongeneration-phase state))))

(defn- ^Boolean state-current-under-lock? [^SubscriptionRegistry registry ^SubscriptionGeneration state]
  (identical? state (get (deref (subscriptionregistry-generations registry)) (subscriptiongeneration-generation state))))

(defn- clear-handoff! [^SubscriptionGeneration state]
  (.clear ^ArrayBlockingQueue (subscriptiongeneration-handoff state))
  nil)

(defn- retire-under-lock! [^SubscriptionRegistry registry ^SubscriptionGeneration state reason ^Boolean retain-resume]
  (if (generation-live? state) (do
  (reset! (subscriptiongeneration-phase state) :retired)
  (reset! (subscriptiongeneration-retirement state) reason)
  (clear-handoff! state)))
  (if (not retain-resume) (do
  (swap! (subscriptionregistry-generations registry) dissoc (subscriptiongeneration-generation state))))
  nil)

(defn- ^Boolean expire-state-under-lock! [^SubscriptionRegistry registry ^SubscriptionGeneration state now-ns]
  (if (>= now-ns (subscriptiongeneration-lease-deadline-ns state)) (do
  (retire-under-lock! registry state :lease-expired false)
  true) false))

(defn- prune-expired-under-lock! [^SubscriptionRegistry registry now-ns]
  (reduce-kv (fn [removed ^String _generation ^SubscriptionGeneration state] (if (expire-state-under-lock! registry state now-ns) (+ removed 1) removed)) 0 (deref (subscriptionregistry-generations registry))))

(defn- ^String mint-generation-under-lock! [^SubscriptionRegistry registry ^StoreCoordinate coordinate]
  (let [previous (deref (subscriptionregistry-next-generation registry))
   sequence (+ 1 previous)
   ^String generation (str (storecoordinate-incarnation coordinate) ":" sequence)]
  (reset! (subscriptionregistry-next-generation registry) sequence)
  generation))

(defn- require-current-binding! [^StoreCoordinate candidate ^StoreCoordinate current code ^String message]
  (if (not (same-store-history? candidate current)) (do
  (subscription-fail! code message)))
  nil)

(defn- ^StoreCoordinate resume-coordinate-under-lock! [^SubscriptionRegistry registry resume ^StoreCoordinate current now-ns]
  (if resume (let [^String generation (subscriptioncursor-generation resume)
   ^StoreCoordinate requested (subscriptioncursor-coordinate resume)]
  (require-current-binding! requested current :rpc/subscription-incarnation-mismatch "subscription resume cursor belongs to another Store incarnation")
  (if (not (coordinate-at-or-before? requested current)) (do
  (subscription-fail! :rpc/subscription-cursor-ahead "subscription resume cursor is ahead of Store")))
  (let [bind__0 (get (deref (subscriptionregistry-generations registry)) generation)]
  (if bind__0 (let [^SubscriptionGeneration prior bind__0]
  (do
  (if (generation-live? prior) (do
  (subscription-fail! :rpc/subscription-generation-active "subscription resume generation is still active")))
  (if (>= now-ns (subscriptiongeneration-lease-deadline-ns prior)) (do
  (retire-under-lock! registry prior :lease-expired false)
  (subscription-fail! :rpc/subscription-expired "subscription resume generation has expired")))
  (let [reason (deref (subscriptiongeneration-retirement prior))]
  (if (not (contains? #{:disconnected :adapter-failed} reason)) (do
  (subscription-fail! :rpc/subscription-resume-unavailable "subscription generation is not resumable"))))
  (let [^StoreCoordinate acknowledged (deref (subscriptiongeneration-acknowledged prior))]
  (if (not (= acknowledged requested)) (do
  (subscription-fail! :rpc/subscription-resume-cursor-mismatch "subscription resume cursor is not the last ACK")))
  (swap! (subscriptionregistry-generations registry) dissoc generation)
  acknowledged))) (subscription-fail! :rpc/subscription-resume-unavailable "subscription resume generation is unavailable")))) current))

(defn open-session! [^SubscriptionSession session resume lease-ms]
  (let [^SubscriptionRegistry registry (subscriptionsession-registry session)
   exact-lease-ms (require-lease-ms! lease-ms)]
  (locking (subscriptionregistry-lock registry) (if (session-generation session) (do
  (subscription-fail! :rpc/subscription-already-open "subscription session already owns a generation"))) (let [now-ns (registry-now-ns-under-lock! registry)
   _ (prune-expired-under-lock! registry now-ns)
   ^StoreCoordinate current (deref (subscriptionregistry-coordinate registry))
   ^StoreCoordinate acknowledged-coordinate (resume-coordinate-under-lock! registry resume current now-ns)
   ^String generation (mint-generation-under-lock! registry current)
   lease-duration-ns (* (long exact-lease-ms) 1000000)
   lease-deadline-ns (+ now-ns lease-duration-ns)
   ^SubscriptionGeneration state (->SubscriptionGeneration generation current (atom acknowledged-coordinate) (atom current) (atom acknowledged-coordinate) lease-deadline-ns (atom :opening) (atom nil) (ArrayBlockingQueue. subscription-handoff-capacity))
   ^SubscriptionCursor acknowledged (->SubscriptionCursor generation acknowledged-coordinate)
   ^SubscriptionCursor observed (->SubscriptionCursor generation current)]
  (swap! (subscriptionregistry-generations registry) assoc generation state)
  (reset! (subscriptionsession-generation session) state)
  (->SubscriptionOpened acknowledged observed lease-deadline-ns)))))

(defn- ^Boolean offer-coordinate-under-lock! [^SubscriptionGeneration state ^StoreCoordinate observed]
  (let [^StoreCoordinate offered (deref (subscriptiongeneration-offered state))]
  (if (and (generation-live? state) (coordinate-before? offered observed)) (let [^String generation (subscriptiongeneration-generation state)
   handoff (subscriptiongeneration-handoff state)]
  (reset! (subscriptiongeneration-offered state) observed)
  (.poll ^ArrayBlockingQueue handoff)
  (if (not (.offer ^ArrayBlockingQueue handoff observed)) (do
  (subscription-fail! :rpc/subscription-handoff-failed "bounded subscription handoff rejected a notice")))
  true) false)))

(defn publish-coordinate! [^SubscriptionRegistry registry ^StoreCoordinate coordinate]
  (locking (subscriptionregistry-lock registry) (let [now-ns (registry-now-ns-under-lock! registry)
   _ (prune-expired-under-lock! registry now-ns)
   ^StoreCoordinate previous (deref (subscriptionregistry-coordinate registry))]
  (if (same-store-history? previous coordinate) (do
  (if (< (storecoordinate-version coordinate) (storecoordinate-version previous)) (do
  (subscription-fail! :rpc/subscription-version-regressed "published Store coordinate regressed")))
  (reset! (subscriptionregistry-coordinate registry) coordinate)
  (reduce-kv (fn [signalled ^String _generation ^SubscriptionGeneration state] (if (offer-coordinate-under-lock! state coordinate) (+ signalled 1) signalled)) 0 (deref (subscriptionregistry-generations registry)))) (do
  (reduce-kv (fn [_ignored ^String _generation ^SubscriptionGeneration state] (retire-under-lock! registry state :store-changed false)
  nil) nil (deref (subscriptionregistry-generations registry)))
  (reset! (subscriptionregistry-generations registry) {})
  (reset! (subscriptionregistry-coordinate registry) coordinate)
  0)))))

(defn ^Boolean activate-open! [^SubscriptionSession session]
  (let [^SubscriptionRegistry registry (subscriptionsession-registry session)]
  (locking (subscriptionregistry-lock registry) (let [bind__1 (session-generation session)]
  (if bind__1 (let [^SubscriptionGeneration state bind__1]
  (let [now-ns (registry-now-ns-under-lock! registry)]
  (if (expire-state-under-lock! registry state now-ns) false (if (and (state-current-under-lock? registry state) (= :opening (deref (subscriptiongeneration-phase state)))) (do
  (reset! (subscriptiongeneration-delivered state) (subscriptiongeneration-opened state))
  (reset! (subscriptiongeneration-phase state) :active)
  true) false)))) false)))))

(defn poll-notice! [^SubscriptionSession session wait-ms]
  (let [state (session-generation session)]
  (if (and state (generation-live? state)) (let [value (.poll ^ArrayBlockingQueue (subscriptiongeneration-handoff state) (max 0 wait-ms) TimeUnit/MILLISECONDS)]
  (cond
  (nil? value) nil
  (instance? StoreCoordinate value) (let [^SubscriptionRegistry registry (subscriptionsession-registry session)]
  (locking (subscriptionregistry-lock registry) (if (and (state-current-under-lock? registry state) (generation-live? state)) (->SubscriptionNotice (->SubscriptionCursor (subscriptiongeneration-generation state) (deref (subscriptiongeneration-acknowledged state))) (->SubscriptionCursor (subscriptiongeneration-generation state) value)) nil)))
  :else (subscription-fail! :rpc/subscription-invalid-state "subscription handoff contains an invalid value"))) nil)))

(defn ^Boolean mark-delivered! [^SubscriptionSession session ^SubscriptionNotice notice]
  (let [^SubscriptionRegistry registry (subscriptionsession-registry session)]
  (locking (subscriptionregistry-lock registry) (let [bind__2 (session-generation session)]
  (if bind__2 (let [^SubscriptionGeneration state bind__2]
  (let [^SubscriptionCursor observed (subscriptionnotice-observed notice)
   ^StoreCoordinate observed-coordinate (subscriptioncursor-coordinate observed)
   ^StoreCoordinate offered (deref (subscriptiongeneration-offered state))
   ^StoreCoordinate delivered (deref (subscriptiongeneration-delivered state))]
  (if (and (state-current-under-lock? registry state) (= :active (deref (subscriptiongeneration-phase state))) (= (subscriptiongeneration-generation state) (subscriptioncursor-generation observed)) (coordinate-at-or-before? observed-coordinate offered)) (do
  (if (coordinate-before? delivered observed-coordinate) (do
  (reset! (subscriptiongeneration-delivered state) observed-coordinate)))
  true) false))) false)))))

(defn acknowledge! [^SubscriptionSession session ^SubscriptionCursor cursor]
  (let [^SubscriptionRegistry registry (subscriptionsession-registry session)]
  (locking (subscriptionregistry-lock registry) (let [now-ns (registry-now-ns-under-lock! registry)
   ^SubscriptionGeneration state (let [bind__3 (session-generation session)]
  (if bind__3 (let [^SubscriptionGeneration present bind__3]
  present) (subscription-fail! :rpc/subscription-unavailable "subscription session has no generation")))]
  (if (expire-state-under-lock! registry state now-ns) (do
  (subscription-fail! :rpc/subscription-expired "subscription generation has expired")))
  (if (not (and (state-current-under-lock? registry state) (= :active (deref (subscriptiongeneration-phase state))))) (do
  (subscription-fail! :rpc/subscription-unavailable "subscription generation is not active")))
  (if (not (= (subscriptiongeneration-generation state) (subscriptioncursor-generation cursor))) (do
  (subscription-fail! :rpc/subscription-generation-mismatch "ACK names another subscription generation")))
  (let [^StoreCoordinate coordinate (subscriptioncursor-coordinate cursor)
   ^StoreCoordinate current (deref (subscriptionregistry-coordinate registry))
   ^StoreCoordinate acknowledged (deref (subscriptiongeneration-acknowledged state))
   ^StoreCoordinate delivered (deref (subscriptiongeneration-delivered state))]
  (require-current-binding! coordinate current :rpc/subscription-incarnation-mismatch "ACK belongs to another Store incarnation")
  (if (coordinate-before? coordinate acknowledged) (do
  (subscription-fail! :rpc/subscription-stale-ack "ACK regresses the subscription cursor")))
  (if (not (coordinate-at-or-before? coordinate delivered)) (do
  (subscription-fail! :rpc/subscription-unobserved-ack "ACK names an undelivered Store coordinate")))
  (reset! (subscriptiongeneration-acknowledged state) coordinate)
  (->SubscriptionAcknowledged (->SubscriptionCursor (subscriptiongeneration-generation state) coordinate) current))))))

(defn retire-session! [^SubscriptionSession session reason]
  (let [^SubscriptionRegistry registry (subscriptionsession-registry session)]
  (locking (subscriptionregistry-lock registry) (let [bind__4 (session-generation session)]
  (if bind__4 (let [^SubscriptionGeneration state bind__4]
  (do
  (if (generation-live? state) (do
  (retire-under-lock! registry state reason (contains? #{:disconnected :adapter-failed} reason)))))))))
  nil))

(defn ^Boolean expire-if-due! [^SubscriptionSession session]
  (let [^SubscriptionRegistry registry (subscriptionsession-registry session)]
  (locking (subscriptionregistry-lock registry) (let [bind__5 (session-generation session)]
  (if bind__5 (let [^SubscriptionGeneration state bind__5]
  (let [now-ns (registry-now-ns-under-lock! registry)]
  (expire-state-under-lock! registry state now-ns))) false)))))

(defn lease-remaining-ns! [^SubscriptionSession session]
  (let [^SubscriptionRegistry registry (subscriptionsession-registry session)]
  (locking (subscriptionregistry-lock registry) (let [bind__6 (session-generation session)]
  (if bind__6 (let [^SubscriptionGeneration state bind__6]
  (max 0 (- (subscriptiongeneration-lease-deadline-ns state) (registry-now-ns-under-lock! registry)))) 0)))))

(defn ^Boolean session-active? [^SubscriptionSession session]
  (let [bind__7 (session-generation session)]
  (if bind__7 (let [^SubscriptionGeneration state bind__7]
  (= :active (deref (subscriptiongeneration-phase state)))) false)))

(defn ^Boolean session-opening? [^SubscriptionSession session]
  (let [bind__8 (session-generation session)]
  (if bind__8 (let [^SubscriptionGeneration state bind__8]
  (= :opening (deref (subscriptiongeneration-phase state)))) false)))

(defn ^Boolean session-terminal? [^SubscriptionSession session]
  (let [bind__9 (session-generation session)]
  (if bind__9 (let [^SubscriptionGeneration state bind__9]
  (= :retired (deref (subscriptiongeneration-phase state)))) true)))

(defn session-retirement [^SubscriptionSession session]
  (let [bind__10 (session-generation session)]
  (if bind__10 (let [^SubscriptionGeneration state bind__10]
  (deref (subscriptiongeneration-retirement state))) nil)))

(defn ^Boolean retirement-closes-adapter? [^SubscriptionSession session]
  (contains? #{:store-changed :registry-reset} (session-retirement session)))

(defn active-generation-count! [^SubscriptionRegistry registry]
  (locking (subscriptionregistry-lock registry) (let [now-ns (registry-now-ns-under-lock! registry)
   _ (prune-expired-under-lock! registry now-ns)]
  (reduce-kv (fn [active ^String _generation ^SubscriptionGeneration state] (if (generation-live? state) (+ active 1) active)) 0 (deref (subscriptionregistry-generations registry))))))

(defn reset-registry! [^SubscriptionRegistry registry]
  (locking (subscriptionregistry-lock registry) (reduce-kv (fn [_ignored ^String _generation ^SubscriptionGeneration state] (retire-under-lock! registry state :registry-reset false)
  nil) nil (deref (subscriptionregistry-generations registry))) (reset! (subscriptionregistry-generations registry) {}))
  nil)

(defn decode-command! [operation payload]
  (cond
  (= operation :rpc/subscribe) (let [[resume-option lease-value] (rpc/rpc-subscription-request-fields! payload)
   resume (if (rpc/rpc-option-present?! resume-option) (wire-cursor! (rpc/rpc-option-value! resume-option)) nil)
   lease-ms (require-lease-ms! lease-value)]
  (->OpenSubscription resume lease-ms))
  (= operation :rpc/subscription-ack) (let [[cursor-value] (rpc/rpc-subscription-ack-fields! payload)]
  (->AcknowledgeSubscription (wire-cursor! cursor-value)))
  :else (subscription-fail! :rpc/unsupported-operation "operation is not a subscription operation")))

(defn handle-command! [^SubscriptionSession session command]
  (let [match__0 command]
  (cond
    (instance? OpenSubscription match__0) (let [resume (:resume match__0) lease-ms (:lease-ms match__0)] (open-session! session resume lease-ms))
    (instance? AcknowledgeSubscription match__0) (let [cursor (:cursor match__0)] (acknowledge! session cursor)))))

(defn outcome-payload! [outcome]
  (let [match__1 outcome]
  (cond
    (instance? SubscriptionOpened match__1) (let [acknowledged (:acknowledged match__1) observed (:observed match__1) _lease-deadline-ns (:lease-deadline-ns match__1)] (rpc/rpc-subscription-open! (cursor-wire! acknowledged) (cursor-wire! observed)))
    (instance? SubscriptionAcknowledged match__1) (let [cursor (:cursor match__1) _observed (:observed match__1)] (rpc/rpc-subscription-acknowledged! (cursor-wire! cursor))))))

(defn ^StoreCoordinate outcome-observed [outcome]
  (let [match__2 outcome]
  (cond
    (instance? SubscriptionOpened match__2) (let [_acknowledged (:acknowledged match__2) observed (:observed match__2) _lease-deadline-ns (:lease-deadline-ns match__2)] (subscriptioncursor-coordinate observed))
    (instance? SubscriptionAcknowledged match__2) (let [_cursor (:cursor match__2) observed (:observed match__2)] observed))))

(defn notice-payload! [^SubscriptionNotice notice]
  (rpc/rpc-subscription-event! (cursor-wire! (subscriptionnotice-acknowledged notice)) (cursor-wire! (subscriptionnotice-observed notice))))

(defn handle-rpc-request! [^SubscriptionSession session request]
  (let [^String space (t/rpcrequest-space request)
   operation (t/rpcrequest-op request)
   ^StoreCoordinate current (current-coordinate (subscriptionsession-registry session))]
  (if (not (= space (storecoordinate-space current))) (do
  (subscription-fail! :rpc/space-mismatch "subscription request belongs to another Store space")))
  (if (t/rpcrequest-expected-version request) (do
  (subscription-fail! :rpc/unexpected-expected-version "subscription requests carry their coordinate in the typed payload")))
  (if (t/rpcrequest-page request) (do
  (subscription-fail! :rpc/unexpected-page "subscription requests do not support paging")))
  (if (t/rpcrequest-timeout-ms request) (do
  (subscription-fail! :rpc/unexpected-timeout "subscription requests use the generation lease")))
  (let [command (decode-command! operation (t/rpc-request-payload-value request))
   outcome (handle-command! session command)
   ^StoreCoordinate observed (outcome-observed outcome)]
  (rpc/rpc-response! space operation (storecoordinate-version observed) nil nil (outcome-payload! outcome)))))
